{- | Composition root (ARCHITECTURE §2): parses the command line, builds the
runtime resources and runs the chosen subcommand.
-}
module Main
  ( main
  ) where

import Control.Exception.Safe (finally)
import Flipstone.Prelude
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStr, hPutStrLn, stderr)
import System.Log.FastLogger qualified as FL
import Text.Show (show)

import Lockstep.Foundation.Cli (Command (Serve), parseArgs, renderCliError, usage)
import Lockstep.Foundation.Config (ServeConfig (..), bindHostAddress, portNumber)
import Lockstep.Web.Application (application)
import Lockstep.Web.Server (serverSettings)

main :: IO ()
main = do
  args <- getArgs
  case parseArgs args of
    Left err -> do
      hPutStrLn stderr ("lockstep: " <> renderCliError err)
      hPutStr stderr usage
      exitWith (ExitFailure 64)
    Right (Serve serveConfig) ->
      serve serveConfig

serve :: ServeConfig -> IO ()
serve serveConfig = do
  (appLogger, finishLogger) <- FL.newFastLogger (FL.LogStdout FL.defaultBufSize)
  let
    address =
      bindHostAddress (serveHost serveConfig)
        <> ":"
        <> show (portNumber (servePort serveConfig))
    settings =
      Warp.setBeforeMainLoop
        (appLogger (FL.toLogStr ("Listening on " <> address <> " (liveness only)\n")))
        (serverSettings serveConfig)
  Warp.runSettings settings (application serveConfig appLogger)
    `finally` finishLogger
