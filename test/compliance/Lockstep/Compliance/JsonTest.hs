{-# LANGUAGE OverloadedStrings #-}

{- | Compatibility proof for the json-fleece conversion (stack-compliance pass,
2026-11-07).

Records: each record now written through a json-fleece schema is compared,
byte for byte, with what the hand-built JSON tree it replaced
("Lockstep.Foundation.Json") wrote for the same values. The trees below are
the replaced expressions, kept here as the oracle. Equal bytes mean equal
record digests, so records written before and after compare as before. The
values exercise the escaping (quotes, backslashes, control characters,
non-ASCII and characters above U+FFFF), optional and null fields.

Responses: the browser JSON bodies keep their shape and markup safety, and
characters above U+FFFF are now valid JSON (a surrogate pair) that decodes
back to the same text.
-}
module Lockstep.Compliance.JsonTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fleece.Aeson qualified as FA
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))
import Text.Show (Show)

import Lockstep.Application.EngineCandidate (candidateJson)
import Lockstep.Application.EngineRecords
  ( AcceptanceRecord (..)
  , Baseline (..)
  , BasisRecord (..)
  , Completion (..)
  , ContractCriterion (..)
  , ContractRecord (..)
  , ContractTest (..)
  , FindingRecord (..)
  , FreezeRecord (..)
  , Halt (..)
  , ImplementationRecord (..)
  , ImplementationRefused (..)
  , InputRecord (..)
  , Refusal (..)
  , Reproduction (..)
  , Resume (..)
  , ReviewRecord (..)
  , Started (..)
  , Unfinished (..)
  , VerificationRun (..)
  , VerificationSummary (..)
  , acceptanceSchema
  , argvText
  , baselineSchema
  , basisSchema
  , completionSchema
  , contractSchema
  , findingSchema
  , freezeSchema
  , haltSchema
  , implementationRefusedSchema
  , implementationSchema
  , inputSchema
  , record
  , refusalSchema
  , reproductionSchema
  , resumeSchema
  , reviewSchema
  , startedSchema
  , unfinishedSchema
  , verificationSchema
  , verificationSummarySchema
  )
import Lockstep.Application.Execution (bugFixDocument)
import Lockstep.Application.ProjectChecks (basicChecksDocument)
import Lockstep.Effects.Roles (encodeDiscovery)
import Lockstep.Foundation.Json (Json (..), renderJson, string, strings)
import Lockstep.Kernel.Candidate (MutantRun (..), mutantRuns)
import Lockstep.Kernel.Roles
  ( Candidate (..)
  , CandidateTest (..)
  , Check (..)
  , Citation (..)
  , Criterion (..)
  , Discovery (..)
  , Expectation (..)
  , Verdict (..)
  )
import Lockstep.Kernel.Runner (OutcomeKind (..))
import Lockstep.Kernel.Transaction (BaselineClass (..), Disposition (..), Stage (..), StateName (..))
import Lockstep.Web.Json
  ( ErrorBody (..)
  , FolderEntry (..)
  , FolderListBody (..)
  , IdBody (..)
  , ResultBody (..)
  , SessionBody (..)
  , StateBody (..)
  , UrlBody (..)
  , encodeBody
  , errorSchema
  , folderListSchema
  , idSchema
  , resultSchema
  , sessionSchema
  , stateSchema
  , urlSchema
  )

-- | Text that exercises every escaping rule.
awkward :: T.Text
awkward =
  "q\"b\\s/\n\r\t\b\f\SOH\DEL é 😀 <>& \8232 end"

rendered :: Json -> T.Text
rendered =
  renderJson

{- | For every value of an enumeration field and the exact text 'FC.text'
wrote for it before (the oracle, spelt out): the record's bytes equal the
hand-built tree with that text; those bytes read back to the value; and the
same tree with a name no value has does not read.
-}
enumField :: (Eq a, Show a) => [(a, T.Text)] -> (r -> Json) -> (LBS.ByteString -> Either String r) -> (a -> r) -> (r -> a) -> (T.Text -> [(T.Text, Json)]) -> Assertion
enumField table encode decode build field oracle = do
  traverse_
    ( \(value, text) -> do
        rendered (encode (build value)) @?= rendered (JObject (oracle text))
        fmap field (decode (LBS.fromStrict (TE.encodeUtf8 (rendered (JObject (oracle text)))))) @?= Right value
    )
    table
  assertBool "an unknown name does not read" (isLeft (decode (LBS.fromStrict (TE.encodeUtf8 (rendered (JObject (oracle "no-such-name")))))))

stages :: [(Stage, T.Text)]
stages =
  [ (StageBasis, "basis")
  , (StageDiscovery, "discovery")
  , (StageReproduction, "reproduction")
  , (StageCandidate, "candidate")
  , (StageChallengePre, "challenge-pre")
  , (StageFreeze, "freeze")
  , (StageImplement, "implement")
  , (StageVerify, "verify")
  , (StageChallengePost, "challenge-post")
  , (StageReview, "review")
  , (StageAccept, "accept")
  ]

states :: [(StateName, T.Text)]
states =
  [(StateRunning, "running"), (StateHalted, "halted"), (StateAccepted, "accepted"), (StateDone, "done"), (StateStopped, "stopped")]

outcomeKinds :: [(OutcomeKind, T.Text)]
outcomeKinds =
  [ (KindExited, "exited")
  , (KindTimedOut, "timed-out")
  , (KindOutputLimit, "output-limit")
  , (KindOutputHeld, "output-held")
  , (KindCancelled, "cancelled")
  , (KindLaunchFailed, "launch-failed")
  , (KindProviderStopped, "provider-stopped")
  ]

expectations :: [(Expectation, T.Text)]
expectations =
  [(ExpectRed, "red"), (ExpectGreen, "green")]

classes :: [(BaselineClass, T.Text)]
classes =
  [ (RedConfirmed, "red-confirmed")
  , (RedUnexpectedlyPassed, "red-unexpectedly-passed")
  , (RedWrongReason, "red-wrong-reason")
  , (GreenConfirmed, "green-confirmed")
  , (GreenCandidateFailed, "green-candidate-failed")
  , (RunFailed, "run-failed")
  ]

mutants :: [(MutantRun, T.Text)]
mutants =
  [ (NoMutant, "none")
  , (MutantOutsideScope, "outside-scope")
  , (MutantKilled, "killed")
  , (MutantSurvived True, "survived-demonstrated")
  , (MutantSurvived False, "survived-not-demonstrated")
  ]

dispositions :: [(Disposition, T.Text)]
dispositions =
  [(Confirmed, "CONFIRMED"), (Disproved, "DISPROVED"), (NeedsHumanFinding, "NEEDS_HUMAN"), (Inconclusive, "INCONCLUSIVE")]

verdicts :: [(Verdict, T.Text)]
verdicts =
  [(Approve, "approve"), (Reject, "reject"), (NeedsHuman, "needs-human")]

tests :: TestTree
tests =
  testGroup
    "json-fleece conversion (stack compliance)"
    [ testGroup
        "records: the same bytes as the hand-built tree"
        [ testCase "started, halt, input, resume, completion, unfinished, refusal, basis" $ do
            rendered (record startedSchema (Started awkward "ada" "/p"))
              @?= rendered (JObject [("work_order", string awkward), ("engineer", string "ada"), ("folder", string "/p")])
            rendered (record haltSchema (Halt StageVerify awkward))
              @?= rendered (JObject [("stage", string "verify"), ("code", string awkward)])
            rendered (record inputSchema (InputRecord "basis-ready" StateRunning))
              @?= rendered (JObject [("input", string "basis-ready"), ("state", string "running")])
            rendered (record resumeSchema (Resume "r1" awkward 7))
              @?= rendered (JObject [("request", string "r1"), ("choice", string awkward), ("revision", JNumber 7)])
            rendered (record completionSchema (Completion "done" "application" awkward))
              @?= rendered (JObject [("choice", string "done"), ("channel", string "application"), ("evidence", string awkward)])
            rendered (record unfinishedSchema (Unfinished ["a", awkward]))
              @?= rendered (JObject [("invocations", strings ["a", awkward])])
            rendered (record unfinishedSchema (Unfinished []))
              @?= rendered (JObject [("invocations", strings [])])
            rendered (record refusalSchema (Refusal awkward))
              @?= rendered (JObject [("code", string awkward)])
            rendered (record basisSchema (BasisRecord "c" "t" awkward))
              @?= rendered (JObject [("commit", string "c"), ("tree", string "t"), ("branch", string awkward)])
        , testCase "reproduction: without a command, and with one that did or did not exit" $ do
            rendered (record reproductionSchema (Reproduction Nothing Nothing Nothing Nothing False Nothing Nothing Nothing))
              @?= rendered (JObject [("command", JNull), ("reproduced", JBool False)])
            let
              ran exit =
                Reproduction (Just ["python3", awkward]) (Just awkward) (Just KindExited) (Just exit) True (Just awkward) (Just "") (Just "inv")
              oracle exit =
                JObject
                  [ ("command", strings ["python3", awkward])
                  , ("signature", string awkward)
                  , ("outcome", string "exited")
                  , ("exit", maybe JNull JNumber exit)
                  , ("reproduced", JBool True)
                  , ("stdout_tail", string awkward)
                  , ("stderr_tail", string "")
                  , ("invocation", string "inv")
                  ]
            rendered (record reproductionSchema (ran (Just 1))) @?= rendered (oracle (Just 1))
            rendered (record reproductionSchema (ran Nothing)) @?= rendered (oracle Nothing)
        , testCase "baseline, finding, freeze, implementation-refused, implementation, acceptance" $ do
            rendered (record baselineSchema (Baseline awkward ExpectRed RedConfirmed KindExited awkward "e"))
              @?= rendered (JObject [("path", string awkward), ("expect", string "red"), ("class", string "red-confirmed"), ("outcome", string "exited"), ("stdout_tail", string awkward), ("stderr_tail", string "e")])
            rendered (record findingSchema (FindingRecord "r" awkward (Just True) MutantKilled Disproved))
              @?= rendered (JObject [("requirement", string "r"), ("claim", string awkward), ("grounded", JBool True), ("mutant", string "killed"), ("disposition", string "DISPROVED")])
            rendered (record freezeSchema (FreezeRecord "f" awkward "d"))
              @?= rendered (JObject [("commit", string "f"), ("branch", string awkward), ("contract_digest", string "d")])
            rendered (record implementationRefusedSchema (ImplementationRefused "no-change" [] "inv"))
              @?= rendered (JObject [("code", string "no-change"), ("paths", strings []), ("invocation", string "inv")])
            rendered (record implementationSchema (ImplementationRecord awkward ["a.py", awkward] "cand" 2 "inv"))
              @?= rendered (JObject [("summary", string awkward), ("changed", strings ["a.py", awkward]), ("candidate", string "cand"), ("attempt", JNumber 2), ("invocation", string "inv")])
            rendered (record acceptanceSchema (AcceptanceRecord "c" awkward "f"))
              @?= rendered (JObject [("commit", string "c"), ("branch", string awkward), ("from", string "f")])
        , testCase "verification (exit only when it exited), verification-summary, review" $ do
            rendered (record verificationSchema (VerificationRun ["sh", awkward] KindExited (Just 0) awkward ""))
              @?= rendered (JObject [("command", strings ["sh", awkward]), ("outcome", string "exited"), ("exit", JNumber 0), ("stdout_tail", string awkward), ("stderr_tail", string "")])
            rendered (record verificationSchema (VerificationRun ["sh"] KindTimedOut Nothing "" ""))
              @?= rendered (JObject [("command", strings ["sh"]), ("outcome", string "timed-out"), ("stdout_tail", string ""), ("stderr_tail", string "")])
            rendered (record verificationSummarySchema (VerificationSummary "c" True))
              @?= rendered (JObject [("commit", string "c"), ("passed", JBool True)])
            rendered (record reviewSchema (ReviewRecord "c" Approve [awkward] (Just "inv")))
              @?= rendered (JObject [("commit", string "c"), ("verdict", string "approve"), ("reasons", strings [awkward]), ("invocation", string "inv")])
        , testCase "the frozen Contract: its bytes, and so its contract_digest" $
            rendered (record contractSchema (ContractRecord "b" "f" [ContractCriterion "c1" awkward] ["calc.py"] [["python3", "-m", "unittest"]] [ContractTest awkward "abc" ["python3", awkward]]))
              @?= rendered
                ( JObject
                    [ ("basis", string "b")
                    , ("freeze", string "f")
                    , ("criteria", JArray [JObject [("id", string "c1"), ("text", string awkward)]])
                    , ("allowed_paths", strings ["calc.py"])
                    , ("verification", JArray [strings ["python3", "-m", "unittest"]])
                    , ("tests", JArray [JObject [("path", string awkward), ("sha256", string "abc"), ("argv", strings ["python3", awkward])]])
                    ]
                )
        , testCase "the candidate, through the answer schema: the same bytes as its hand-built answer form" $ do
            let
              citation = Citation awkward 1 20
              candidate =
                Candidate
                  [Criterion "c1" awkward "quote" [citation]]
                  ["calc.py"]
                  [["python3", "-m", "unittest", awkward]]
                  [CandidateTest "t.py" awkward ExpectRed ["python3", "t.py"] (Just awkward), CandidateTest "u.py" "x" ExpectGreen ["python3"] Nothing]
              citationJson c = JObject [("path", string (citationPath c)), ("first", JNumber (toInteger (citationFirst c))), ("last", JNumber (toInteger (citationLast c)))]
              oracle =
                JObject
                  [ ("kind", string "candidate")
                  , ("criteria", JArray [JObject [("id", string "c1"), ("text", string awkward), ("ticket_quote", string "quote"), ("citations", JArray [citationJson citation])]])
                  , ("allowed_paths", strings ["calc.py"])
                  , ("verification", JArray [strings ["python3", "-m", "unittest", awkward]])
                  ,
                    ( "tests"
                    , JArray
                        [ JObject [("path", string "t.py"), ("content", string awkward), ("expect", string "red"), ("argv", strings ["python3", "t.py"]), ("signature", string awkward)]
                        , JObject [("path", string "u.py"), ("content", string "x"), ("expect", string "green"), ("argv", strings ["python3"])]
                        ]
                    )
                  ]
            rendered (candidateJson candidate) @?= rendered oracle
        , testCase "the discovery, through the answer schema: the answer schema's key order (reproduction before allowed_paths)" $ do
            let
              discovery = Discovery awkward "h" [Citation "a.py" 1 2] (Just (Check ["sh", awkward] "sig")) ["a.py"]
            encodeDiscovery discovery
              @?= rendered
                ( JObject
                    [ ("kind", string "discovery")
                    , ("summary", string awkward)
                    , ("hypothesis", string "h")
                    , ("citations", JArray [JObject [("path", string "a.py"), ("first", JNumber 1), ("last", JNumber 2)]])
                    , ("reproduction", JObject [("argv", strings ["sh", awkward]), ("signature", string "sig")])
                    , ("allowed_paths", strings ["a.py"])
                    ]
                )
        , testCase "an invocation's argument vector" $
            argvText ["sh", "-c", awkward] @?= rendered (strings ["sh", "-c", awkward])
        ]
    , testGroup
        "records: typed enumeration fields (Increment C) write the text they replaced, read it back, and refuse unknown names"
        [ testCase "halt stage" $
            enumField stages (record haltSchema) (FA.decode haltSchema) (`Halt` "c") haltStage (\t -> [("stage", string t), ("code", string "c")])
        , testCase "input state" $
            enumField states (record inputSchema) (FA.decode inputSchema) (InputRecord "i") inputState (\t -> [("input", string "i"), ("state", string t)])
        , testCase "baseline expectation, class and outcome" $ do
            let
              baseline e c k = Baseline "p" e c k "o" "e"
              oracle e c k = [("path", string "p"), ("expect", string e), ("class", string c), ("outcome", string k), ("stdout_tail", string "o"), ("stderr_tail", string "e")]
            enumField expectations (record baselineSchema) (FA.decode baselineSchema) (\e -> baseline e RedConfirmed KindExited) baselineExpect (\t -> oracle t "red-confirmed" "exited")
            enumField classes (record baselineSchema) (FA.decode baselineSchema) (\c -> baseline ExpectGreen c KindExited) baselineClass (\t -> oracle "green" t "exited")
            enumField outcomeKinds (record baselineSchema) (FA.decode baselineSchema) (baseline ExpectRed RunFailed) baselineOutcome (oracle "red" "run-failed")
        , testCase "reproduction outcome" $
            enumField
              outcomeKinds
              (record reproductionSchema)
              (FA.decode reproductionSchema)
              (\k -> Reproduction (Just ["sh"]) (Just "s") (Just k) (Just (Just 1)) True (Just "o") (Just "e") (Just "inv"))
              (fromMaybe KindCancelled . reproductionOutcome)
              (\t -> [("command", strings ["sh"]), ("signature", string "s"), ("outcome", string t), ("exit", JNumber 1), ("reproduced", JBool True), ("stdout_tail", string "o"), ("stderr_tail", string "e"), ("invocation", string "inv")])
        , testCase "finding mutant and disposition" $ do
            let
              oracle m d = [("requirement", string "r"), ("claim", string "c"), ("grounded", JBool False), ("mutant", string m), ("disposition", string d)]
            enumField mutants (record findingSchema) (FA.decode findingSchema) (\m -> FindingRecord "r" "c" (Just False) m Confirmed) findingRecordMutant (`oracle` "CONFIRMED")
            enumField dispositions (record findingSchema) (FA.decode findingSchema) (FindingRecord "r" "c" (Just False) NoMutant) findingRecordDisposition (oracle "none")
        , testCase "verification outcome" $
            enumField outcomeKinds (record verificationSchema) (FA.decode verificationSchema) (\k -> VerificationRun ["sh"] k (Just 1) "o" "e") runOutcome (\t -> [("command", strings ["sh"]), ("outcome", string t), ("exit", JNumber 1), ("stdout_tail", string "o"), ("stderr_tail", string "e")])
        , testCase "review verdict" $
            enumField verdicts (record reviewSchema) (FA.decode reviewSchema) (\v -> ReviewRecord "c" v ["x"] (Just "i")) reviewVerdict (\t -> [("commit", string "c"), ("verdict", string t), ("reasons", strings ["x"]), ("invocation", string "i")])
        , testCase "every value of each enumeration is in its table" $ do
            fmap fst stages @?= [minBound .. maxBound]
            fmap fst states @?= [minBound .. maxBound]
            fmap fst outcomeKinds @?= [minBound .. maxBound]
            fmap fst expectations @?= [minBound .. maxBound]
            fmap fst classes @?= [minBound .. maxBound]
            fmap fst dispositions @?= [minBound .. maxBound]
            fmap fst verdicts @?= [minBound .. maxBound]
            fmap fst mutants @?= mutantRuns
        ]
    , testGroup
        "built-in Profile documents: the bytes stored rows and their digests hold"
        [ testCase "lockstep-basic" $
            basicChecksDocument @?= "{\"id\":\"lockstep-basic\",\"version\":1,\"gates\":[]}"
        , testCase "lockstep-bug-fix" $
            let
              gate name artifacts verifiers exceptionPath =
                "{\"id\":\""
                  <> name
                  <> "\",\"stage\":\"before-acceptance\",\"artifacts\":"
                  <> artifacts
                  <> ",\"kinds\":[\"engineering\"],\"classes\":[\"bug\"],\"verifiers\":"
                  <> verifiers
                  <> ",\"approval\":\"supervisor\",\"exception_path\":"
                  <> (if exceptionPath then "true" else "false")
                  <> "}"
              oracle =
                "{\"id\":\"lockstep-bug-fix\",\"version\":1,\"gates\":["
                  <> gate "bug-reproduction" "[\"reproduction\"]" "[\"deterministic-command\"]" True
                  <> ","
                  <> gate "bug-requirements" "[\"impact-assessment\",\"requirements-basis\"]" "[\"digest-check\"]" False
                  <> ","
                  <> gate "bug-regression-test" "[\"frozen-tests\"]" "[\"deterministic-command\",\"digest-check\"]" False
                  <> ","
                  <> gate "bug-verification" "[\"regression-evidence\",\"verification-record\"]" "[\"deterministic-command\"]" False
                  <> ","
                  <> gate "bug-review" "[\"review-record\"]" "[\"independent-review\"]" False
                  <> "]}"
            in
              bugFixDocument @?= oracle
        ]
    , testGroup
        "browser responses: shape, markup safety, valid JSON"
        [ testCase "bodies are compact, with their keys in order" $ do
            encodeBody errorSchema (ErrorBody "not-found") @?= "{\"error\":\"not-found\"}"
            encodeBody sessionSchema (SessionBody "abc") @?= "{\"session\":\"abc\"}"
            encodeBody idSchema (IdBody "r-1") @?= "{\"id\":\"r-1\"}"
            encodeBody urlSchema (UrlBody "http://127.0.0.1:1/x") @?= "{\"url\":\"http://127.0.0.1:1/x\"}"
            encodeBody stateSchema (StateBody "pending") @?= "{\"state\":\"pending\"}"
            encodeBody folderListSchema (FolderListBody "d" [FolderEntry "rw" "/a b", FolderEntry "ro" "/c"])
              @?= "{\"digest\":\"d\",\"folders\":[{\"mode\":\"rw\",\"path\":\"/a b\"},{\"mode\":\"ro\",\"path\":\"/c\"}]}"
        , testCase "a result: null reason, numbers, fields by name" $
            encodeBody resultSchema (ResultBody "done" "r" "status" "ok" Nothing 10 20 (Map.fromList [("service.state", "running"), ("a", "b")]) "fine")
              @?= "{\"state\":\"done\",\"id\":\"r\",\"op\":\"status\",\"outcome\":\"ok\",\"reason\":null,\"started\":10,\"finished\":20,\"fields\":{\"a\":\"b\",\"service.state\":\"running\"},\"detail\":\"fine\"}"
        , testCase "markup characters and non-ASCII are escaped; the response is ASCII" $
            encodeBody errorSchema (ErrorBody "<script>&é\DEL")
              @?= "{\"error\":\"\\u003cscript\\u003e\\u0026\\u00e9\\u007f\"}"
        , testCase "a character above U+FFFF is a surrogate pair and decodes back to itself (J1)" $ do
            let
              body = encodeBody errorSchema (ErrorBody "😀")
            body @?= "{\"error\":\"\\ud83d\\ude00\"}"
            fmap errorCode (FA.decode errorSchema (LBS.fromStrict (TE.encodeUtf8 body))) @?= Right "😀"
        , testCase "control characters, quotes and backslashes round-trip" $
            fmap errorCode (FA.decode errorSchema (LBS.fromStrict (TE.encodeUtf8 (encodeBody errorSchema (ErrorBody awkward))))) @?= Right awkward
        ]
    ]
