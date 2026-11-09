{-# LANGUAGE RoleAnnotations #-}

{- | Form validation, derived from Artificer.Validation (Launchpad's pattern): a
'Validator' is an 'Applicative' that accumulates one error per field, keyed by
the same 'B.Name' the page's input uses, so a form and its parser cannot
disagree on a field's name. Domain checks are chained onto the raw text with
'eitherValidator' / 'maybeValidator' and live with their types. Without
Artificer's file fields, error reporting and response schema (Lockstep's
frozen pages answer a form error with the page and a notice, never a 422).
-}
module Lockstep.Web.Validation
  ( Validator
  , runValidator
  , FormErrors
  , hasError
  , Error (..)
  , valid
  , text
  , list
  , boundedEnum
  , digitsUpTo
  , decimalUpTo
  , labelled
  , chain
  , maybeValidator
  , eitherValidator
  , required
  , optional
  , withDefault
  ) where

import Brigid.Types qualified as B
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NEL
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.NonEmptyText qualified as NET
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Flipstone.Prelude

import Lockstep.Kernel.Enum (parseEnumText)
import Lockstep.Web.Form (Form, FormField (..), field)

type role Validator nominal representational

newtype Validator input a
  = Validator
  { runValidatorInternal :: input -> Result a
  }

instance Functor (Validator input) where
  fmap f v = Validator (fmap f . runValidatorInternal v)

instance Applicative (Validator input) where
  pure = valid
  v <*> w =
    Validator $ \input ->
      runValidatorInternal v input <*> runValidatorInternal w input

-- | What went wrong with one field.
data Error
  = NotFoundError
  | MultipleValuesError
  | UnexpectedFileError
  | ValidationError T.Text
  deriving (Eq)

-- | The errors of a form, one per field name.
newtype FormErrors
  = FormErrors (Map.Map T.Text Error)
  deriving (Semigroup, Monoid)

hasError :: B.Name -> FormErrors -> Bool
hasError (B.Name name) (FormErrors errs) =
  Map.member (NET.toText name) errs

type role Result representational

data Result a
  = Success a
  | Failure FormErrors

instance Functor Result where
  fmap f result =
    case result of
      Success a -> Success (f a)
      Failure e -> Failure e

instance Applicative Result where
  pure = Success
  f <*> a =
    case (f, a) of
      (Success g, Success b) -> Success (g b)
      (Success _, Failure e) -> Failure e
      (Failure e, Success _) -> Failure e
      (Failure e, Failure e') -> Failure (e <> e')

runValidator :: Validator Form a -> Form -> Either FormErrors a
runValidator v form =
  case runValidatorInternal v form of
    Success a -> Right a
    Failure e -> Left e

valid :: a -> Validator input a
valid a =
  Validator (const (Success a))

-- | The key a field's own validator reports under, renamed by 'required' / 'optional'.
reserved :: T.Text
reserved =
  T.pack "reserved_for_errors"

failWith :: Error -> Result a
failWith =
  Failure . FormErrors . Map.singleton reserved

-- | Exactly one text value.
text :: Validator FormField T.Text
text =
  Validator $ \input ->
    case input of
      ParamField (t :| []) -> Success t
      ParamField _ -> failWith MultipleValuesError
      FileField _ -> failWith UnexpectedFileError

-- | Every value of a repeated field, each checked.
list :: Validator FormField a -> Validator FormField [a]
list v =
  Validator $ \input ->
    case input of
      ParamField ts -> traverse (runValidatorInternal v . ParamField . (:| [])) (NEL.toList ts)
      FileField _ -> failWith UnexpectedFileError

{- | A number as the forms and addresses spell it (C-C.R1 R3): plain ASCII decimal
digits only (no sign, space or other spelling), at most 19 of them, and at most
@limit@. The one decimal reader of the web layer ('Data.Text.Read.decimal').
-}
digitsUpTo :: Integer -> T.Text -> Maybe Integer
digitsUpTo limit t
  | T.length t > 19 = Nothing
  | otherwise =
      case TR.decimal t of
        Right (n, rest) | T.null rest, n <= limit -> Just n
        _ -> Nothing

-- | One value: 'digitsUpTo' the limit.
decimalUpTo :: Num a => Integer -> Validator FormField a
decimalUpTo limit =
  text `chain` maybeValidator (fmap fromInteger . digitsUpTo limit) (T.pack "Not a number in range.")

-- | One value, one of the type's canonical spellings.
boundedEnum :: (Bounded a, Enum a) => (a -> T.Text) -> Validator FormField a
boundedEnum toText =
  text `chain` maybeValidator (parseEnumText toText) (T.pack "Not one of the choices.")

{- | A check over several fields (built from 'required' / 'optional' parts),
reported under one field's name.
-}
labelled :: B.Name -> Validator input a -> Validator input a
labelled name v =
  Validator (rename name . runValidatorInternal v)

chain :: Validator input a -> Validator a b -> Validator input b
chain v1 v2 =
  Validator $ \input ->
    case runValidatorInternal v1 input of
      Success a -> runValidatorInternal v2 a
      Failure e -> Failure e

maybeValidator :: (input -> Maybe a) -> T.Text -> Validator input a
maybeValidator fn err =
  Validator (maybe (failWith (ValidationError err)) Success . fn)

eitherValidator :: (input -> Either T.Text a) -> Validator input a
eitherValidator fn =
  Validator (either (failWith . ValidationError) Success . fn)

infixr 5 `required`

required :: B.Name -> Validator FormField a -> Validator Form a
required name v =
  Validator $ \form ->
    case field name form of
      Just f -> rename name (runValidatorInternal v f)
      Nothing -> Failure (FormErrors (Map.singleton (B.nameToText name) NotFoundError))

infixr 5 `optional`

optional :: B.Name -> Validator FormField a -> Validator Form (Maybe a)
optional name v =
  Validator $ \form ->
    case field name form of
      Just f -> Just <$> rename name (runValidatorInternal v f)
      Nothing -> Success Nothing

-- | An absent field reads as the given value.
withDefault :: a -> Validator Form (Maybe a) -> Validator Form a
withDefault a =
  fmap (fromMaybe a)

rename :: B.Name -> Result a -> Result a
rename name result =
  case result of
    Success a -> Success a
    Failure (FormErrors errs) ->
      Failure . FormErrors $
        case Map.lookup reserved errs of
          Just e -> Map.insert (B.nameToText name) e (Map.delete reserved errs)
          Nothing -> errs
