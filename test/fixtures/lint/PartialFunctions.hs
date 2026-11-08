-- | NEGATIVE FIXTURE. scripts/check runs hlint on this file and requires one
-- hint per banned partial function. It is never compiled.
module PartialFunctions
  ( examples
  ) where

import Data.List qualified as L
import Data.Maybe (fromJust)

examples :: [Int] -> Maybe Int -> String -> [Int]
examples xs mb s =
  [ head xs
  , L.last xs
  , xs !! 1
  , fromJust mb
  , read s
  , maximum xs
  , minimum xs
  , foldr1 (+) xs
  , foldl1 (+) xs
  , toEnum 0
  , succ 0
  , pred 0
  , undefined
  , error "boom"
  , errorWithoutStackTrace "boom"
  ]
    <> tail xs
    <> init xs
