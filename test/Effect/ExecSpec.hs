{-# LANGUAGE TemplateHaskell #-}

module Effect.ExecSpec (
  spec,
) where

import App.Types (SystemPath (..), SystemPathExt (..))
import App.Util (SupportedOS (..), runningInOS)
import Control.Carrier.Diagnostics (runDiagnostics)
import Control.Carrier.Finally (runFinally)
import Control.Carrier.Reader (runReader)
import Control.Carrier.Stack (runStack)
import Data.Either (isLeft)
import Data.String.Conversion (ConvertUtf8 (decodeUtf8), toString, toText)
import Data.Text (Text)
import Diag.Result (Result (..))
import Effect.Exec (
  AllowErr (..),
  Command (..),
  FoundLocation (..),
  exec,
  foundLocationToCommand,
  runExecIO,
  which,
 )
import Effect.ReadFS (runReadFSIO)
import Path (mkRelDir, mkRelFile, parseAbsDir, (</>))
import Path.IO (getCurrentDir)
import ResultUtil (assertOnSuccess)
import System.Environment (lookupEnv)
import System.FilePath (splitSearchPath)
import Test.Hspec (
  Spec,
  describe,
  expectationFailure,
  it,
  runIO,
  shouldBe,
  shouldContain,
  shouldSatisfy,
 )
import Prelude

spec :: Spec
spec = do
  dir <- runIO getCurrentDir

  describe "IO-based handler" $ do
    it "should return Left, and not throw an exception, when a command is not found" $ do
      res <- runExecIO $ exec dir (Command "lkajsdflkjasdlfkjas" [] Always)
      res `shouldSatisfy` isLeft

  describe "Path search" $ do
    systemPath <- runIO lookupSystemPath
    systemPathExt <- runIO lookupSystemPathExt

    -- Any project running this test should have cabal in its path, right??
    result <-
      runIO
        . runStack
        . runFinally
        . runDiagnostics
        . runReadFSIO
        . runReader systemPath
        . runReader systemPathExt
        $ which dir "cabal"

    it "should find a binary in path" $ do
      assertOnSuccess result $ \_ location -> do
        case location of
          Just (FoundInSystemPath _ _) -> pure ()
          _ -> expectationFailure "cabal not found in system path"

    it "should report binary name correctly" $ do
      assertOnSuccess result $ \_ location -> do
        case location of
          -- shouldContain because on windows this may have arbitrary extensions, and in all platforms it has an arbitrary path.
          Just (FoundInSystemPath _ name) -> (toString name) `shouldContain` "cabal"
          _ -> expectationFailure "cabal not found in system path"

  describe "Working directory search" $ do
    systemPath <- runIO lookupSystemPath
    systemPathExt <- runIO lookupSystemPathExt
    let testdataDir = dir </> $(mkRelDir "test/Effect/testdata")

    helloDiscovery <-
      runIO
        . runStack
        . runFinally
        . runDiagnostics
        . runReadFSIO
        . runReader systemPath
        . runReader systemPathExt
        $ which testdataDir "hello"

    helloExecution <-
      runIO
        . runStack
        . runFinally
        . runDiagnostics
        . runReadFSIO
        . runReader systemPath
        . runReader systemPathExt
        . runExecIO
        $ do
          case helloDiscovery of
            Success _ (Just loc) -> do
              let cmd = foundLocationToCommand [] Never loc
              result <- exec testdataDir cmd
              case result of
                Left cf -> pure . Left . toText $ "failed to run command: " <> show cf
                Right bs -> pure . Right $ decodeUtf8 @Text bs
            Success _ Nothing -> pure $ Left "hellobin should be found, but was not"
            Failure _ _ -> pure $ Left "hellobin should be found, but got failure running test"

    fakebin <-
      runIO
        . runStack
        . runFinally
        . runDiagnostics
        . runReadFSIO
        . runReader systemPath
        . runReader systemPathExt
        $ which testdataDir "fakebin"

    cabalInWorkingDir <-
      runIO
        . runStack
        . runFinally
        . runDiagnostics
        . runReadFSIO
        . runReader systemPath
        . runReader systemPathExt
        $ which testdataDir "cabal"

    fakebinNonExistent <-
      runIO
        . runStack
        . runFinally
        . runDiagnostics
        . runReadFSIO
        . runReader systemPath
        . runReader systemPathExt
        $ which testdataDir "fakebin_does_not_exist"

    it "should find a binary in working directory" $ do
      assertOnSuccess fakebin $ \_ location -> do
        if runningInOS Windows
          then location `shouldBe` Just (FoundInWorkDir (testdataDir </> $(mkRelFile "fakebin.EXE")) "fakebin")
          else location `shouldBe` Just (FoundInWorkDir (testdataDir </> $(mkRelFile "fakebin")) "fakebin")

    it "should prefer working directory to system path" $ do
      assertOnSuccess cabalInWorkingDir $ \_ location -> do
        if runningInOS Windows
          then location `shouldBe` Just (FoundInWorkDir (testdataDir </> $(mkRelFile "cabal.EXE")) "cabal")
          else location `shouldBe` Just (FoundInWorkDir (testdataDir </> $(mkRelFile "cabal")) "cabal")

    it "should not find a binary that doesn't exist" $ do
      case fakebinNonExistent of
        Success _ (Just loc) -> expectationFailure ("fakebin_does_not_exist should not be found, but got: " <> show loc)
        Success _ Nothing -> pure ()
        Failure _ _ -> expectationFailure "fakebin_does_not_exist should not be found, but got failure running test"

    it "should be able to execute a discovered binary" $ do
      case helloExecution of
        Success _ e -> case e of
          Right output -> output `shouldBe` "hello"
          Left err -> expectationFailure $ "hellobin should have been executed, but failed: " <> toString err
        Failure _ _ -> expectationFailure "hellobin should have been executed, but got failure running test"

lookupSystemPath :: IO SystemPath
lookupSystemPath = do
  env <- lookupEnv systemPath
  case env of
    Nothing -> pure mempty
    Just env' -> SystemPath <$> traverse parseAbsDir (splitSearchPath env')
  where
    systemPath :: String
    systemPath = "PATH"

lookupSystemPathExt :: IO SystemPathExt
lookupSystemPathExt =
  if runningInOS Windows
    then do
      env <- lookupEnv systemPathExt
      case env of
        Nothing -> pure mempty
        Just env' -> pure . SystemPathExt $ splitSearchPath env'
    else pure mempty
  where
    systemPathExt :: String
    systemPathExt = "PATHEXT"
