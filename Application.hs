{-# OPTIONS_GHC -fno-warn-orphans #-}
module Application
    ( makeApplication
    , getApplicationDev
    , makeFoundation
    ) where

import           Control.Concurrent (forkIO, threadDelay)
import           Control.Exception (catch)
import           Control.Monad.Logger (runLoggingT)
import           Data.WebsiteContent
import qualified Database.Persist
import           Import hiding (catch)
import           Language.Haskell.TH.Syntax (Loc(..))
import           Network.Wai (Middleware, responseLBS)
import           Network.Wai.Logger (clockDateCacher)
import           Network.Wai.Middleware.RequestLogger
    ( mkRequestLogger, outputFormat, OutputFormat (..), IPAddrSource (..), destination
    )
import qualified Network.Wai.Middleware.RequestLogger as RequestLogger
import           Settings
import           System.Log.FastLogger (newStdoutLoggerSet, newFileLoggerSet, defaultBufSize, fromLogStr)
import qualified System.Random.MWC as MWC
import           Yesod.Core.Types (loggerSet, Logger (Logger))
import           Yesod.Default.Config
import           Yesod.Default.Handlers
import           Yesod.Default.Main
import           Yesod.GitRepo
import           System.Environment (getEnvironment)
import           System.Process (rawSystem)
import           Stackage.Database (createStackageDatabase, openStackageDatabase)

import qualified Echo

-- Import all relevant handler modules here.
-- Don't forget to add new modules to your cabal file!
import           Handler.Home
import           Handler.Snapshots
import           Handler.Profile
import           Handler.Email
import           Handler.ResetToken
import           Handler.StackageHome
import           Handler.StackageIndex
import           Handler.StackageSdist
import           Handler.System
import           Handler.Haddock
import           Handler.Package
import           Handler.PackageList
import           Handler.Tag
import           Handler.BannedTags
import           Handler.Hoogle
import           Handler.BuildVersion
import           Handler.Sitemap
import           Handler.BuildPlan
import           Handler.Download
import           Handler.OldLinks

-- This line actually creates our YesodDispatch instance. It is the second half
-- of the call to mkYesodData which occurs in Foundation.hs. Please see the
-- comments there for more details.
mkYesodDispatch "App" resourcesApp

-- This function allocates resources (such as a database connection pool),
-- performs initialization and creates a WAI application. This is also the
-- place to put your migrate statements to have automatic database
-- migrations handled by Yesod.
makeApplication :: Bool -- ^ Use Echo.
                -> AppConfig DefaultEnv Extra -> IO (Application, LogFunc)
makeApplication echo@True conf = do
   foundation <- makeFoundation echo conf
   app <- toWaiAppPlain foundation
   logWare <- mkRequestLogger def
       { destination = RequestLogger.Callback (const (return ()))
       }
   Echo.clear
   return (logWare (defaultMiddlewaresNoLogging app),logFunc)
 where logFunc (Loc filename' _pkg _mod (line,_) _) source level str =
           Echo.write (filename',line) (show source ++ ": " ++ show level ++ ": " ++ toStr str)
       toStr = unpack . decodeUtf8 . fromLogStr
makeApplication echo@False conf = do
    foundation <- makeFoundation echo conf
    -- Initialize the logging middleware
    logWare <- mkRequestLogger def
        { outputFormat =
            if development
                then Detailed True
                else Apache FromFallback
        , destination = RequestLogger.Logger $ loggerSet $ appLogger foundation
        }
    -- Create the WAI application and apply middlewares
    app <- toWaiAppPlain foundation
    let logFunc = messageLoggerSource foundation (appLogger foundation)
        middleware = nicerExceptions . logWare . defaultMiddlewaresNoLogging
    return (middleware app, logFunc)

nicerExceptions :: Middleware
nicerExceptions app req send = catch (app req send) $ \e -> do
    let text = "Exception thrown to Warp: " ++ tshow (e :: SomeException)
    putStrLn text
    send $ responseLBS status500 [("Content-Type", "text/plain")] $
        fromStrict $ encodeUtf8 text

getDbConf :: AppConfig DefaultEnv Extra -> IO Settings.PersistConf
getDbConf conf =
    withYamlEnvironment "config/postgresql.yml" (appEnv conf)
    Database.Persist.loadConfig >>=
    Database.Persist.applyEnv

-- | Loads up any necessary settings, creates your foundation datatype, and
-- performs some initialization.
makeFoundation :: Bool -> AppConfig DefaultEnv Extra -> IO App
makeFoundation useEcho conf = do
    manager <- newManager
    s <- staticSite
    dbconf <- getDbConf conf
    p <- Database.Persist.createPoolConfig dbconf

    loggerSet' <- if useEcho
                     then newFileLoggerSet defaultBufSize "/dev/null"
                     else newStdoutLoggerSet defaultBufSize
    (getter, _) <- clockDateCacher

    gen <- MWC.createSystemRandom

    websiteContent' <- if development
        then do
            void $ rawSystem "git"
                [ "clone"
                , "https://github.com/fpco/stackage-content.git"
                ]
            gitRepoDev "stackage-content" loadWebsiteContent
        else gitRepo
            "https://github.com/fpco/stackage-content.git"
            "master"
            loadWebsiteContent

    -- Temporary workaround to force content updates regularly, until
    -- distribution of webhooks is handled via consul
    void $ forkIO $ forever $ void $ tryAny $ do
        threadDelay $ 1000 * 1000 * 60 * 20
        grRefresh websiteContent'

    let dbfile = "stackage.sqlite3"
    createStackageDatabase dbfile
    stackageDatabase' <- openStackageDatabase dbfile
    -- FIXME refresh this on a regular basis

    env <- getEnvironment

    let logger = Yesod.Core.Types.Logger loggerSet' getter
        foundation = App
            { settings = conf
            , getStatic = s
            , connPool = p
            , httpManager = manager
            , persistConfig = dbconf
            , appLogger = logger
            , genIO = gen
            , websiteContent = websiteContent'
            , stackageDatabase = stackageDatabase'
            }

    -- Perform database migration using our application's logging settings.
    when (lookup "STACKAGE_SKIP_MIGRATION" env /= Just "1") $
        runResourceT $
        flip runReaderT gen $
        flip runLoggingT (messageLoggerSource foundation logger) $
        flip (Database.Persist.runPool dbconf) p $ do
            runMigration migrateAll
            {-
            checkMigration 1 fixSnapSlugs
            checkMigration 2 setCorePackages
            -}

    return foundation

-- for yesod devel
getApplicationDev :: Bool -> IO (Int, Application)
getApplicationDev useEcho =
    defaultDevelApp loader (fmap fst . makeApplication useEcho)
  where
    loader = Yesod.Default.Config.loadConfig (configSettings Development)
        { csParseExtra = parseExtra
        }

_checkMigration :: MonadIO m
                => Int
                -> ReaderT SqlBackend m ()
                -> ReaderT SqlBackend m ()
_checkMigration num f = do
    eres <- insertBy $ Migration num
    case eres of
        Left _ -> return ()
        Right _ -> f
