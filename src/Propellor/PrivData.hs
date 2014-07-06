{-# LANGUAGE PackageImports #-}

module Propellor.PrivData where

import Control.Applicative
import System.FilePath
import System.IO
import System.Directory
import Data.Maybe
import Data.Monoid
import Control.Monad
import Control.Monad.IfElse
import "mtl" Control.Monad.Reader
import qualified Data.Map as M
import qualified Data.Set as S

import Propellor.Types
import Propellor.Types.Info
import Propellor.Message
import Utility.Monad
import Utility.PartialPrelude
import Utility.Exception
import Utility.Process
import Utility.Tmp
import Utility.SafeCommand
import Utility.Misc
import Utility.FileMode
import Utility.Env

-- | Allows a Property to access the value of a specific PrivDataField,
-- for use in a specific Context.
--
-- Example use:
--
-- > withPrivData (PrivFile pemfile) (Context "joeyh.name") $ \getdata ->
-- >     property "joeyh.name ssl cert" $ getdata $ \privdata ->
-- >       liftIO $ writeFile pemfile privdata
-- >   where pemfile = "/etc/ssl/certs/web.pem"
-- 
-- Note that if the value is not available, the action is not run
-- and instead it prints a message to help the user make the necessary
-- private data available.
withPrivData
	:: PrivDataField
	-> Context
	-> (((PrivData -> Propellor Result) -> Propellor Result) -> Property)
	-> Property
withPrivData field context@(Context cname) mkprop = addinfo $ mkprop $ \a ->
	maybe missing a =<< liftIO (getLocalPrivData field context)
  where
	missing = liftIO $ do
		warningMessage $ "Missing privdata " ++ show field ++ " (for " ++ cname ++ ")"
		putStrLn $ "Fix this by running: propellor --set '" ++ show field ++ "' '" ++ cname ++ "'"
		return FailedChange
	addinfo p = p { propertyInfo = propertyInfo p <> mempty { _privDataFields = S.singleton (field, context) } }

{- Gets the requested field's value, in the specified context if it's
 - available, from the host's local privdata cache. -}
getLocalPrivData :: PrivDataField -> Context -> IO (Maybe PrivData)
getLocalPrivData field context =
	getPrivData field context . fromMaybe M.empty <$> localcache
  where
	localcache = catchDefaultIO Nothing $ readish <$> readFile privDataLocal

getPrivData :: PrivDataField -> Context -> (M.Map (PrivDataField, Context) PrivData) -> Maybe PrivData
getPrivData field context = M.lookup (field, context)

setPrivData :: PrivDataField -> Context -> IO ()
setPrivData field context = do
	putStrLn "Enter private data on stdin; ctrl-D when done:"
	setPrivDataTo field context =<< hGetContentsStrict stdin

dumpPrivData :: PrivDataField -> Context -> IO ()
dumpPrivData field context =
	maybe (error "Requested privdata is not set.") putStrLn
		=<< (getPrivData field context <$> decryptPrivData)

editPrivData :: PrivDataField -> Context -> IO ()
editPrivData field context = do
	v <- getPrivData field context <$> decryptPrivData
	v' <- withTmpFile "propellorXXXX" $ \f h -> do
		hClose h
		maybe noop (writeFileProtected f) v
		editor <- getEnvDefault "EDITOR" "vi"
		unlessM (boolSystem editor [File f]) $
			error "Editor failed; aborting."
		readFile f
	setPrivDataTo field context v'

listPrivDataFields :: IO ()
listPrivDataFields = do
	m <- decryptPrivData
	putStrLn ("\nAll currently set privdata fields:")
	mapM_ list $ M.keys m
  where
	list = putStrLn . ("\t" ++) . shellEscape . show

setPrivDataTo :: PrivDataField -> Context -> PrivData -> IO ()
setPrivDataTo field context value = do
	makePrivDataDir
	m <- decryptPrivData
	let m' = M.insert (field, context) (chomp value) m
	gpgEncrypt privDataFile (show m')
	putStrLn "Private data set."
	void $ boolSystem "git" [Param "add", File privDataFile]
  where
	chomp s
		| end s == "\n" = chomp (beginning s)
		| otherwise = s

decryptPrivData :: IO (M.Map (PrivDataField, Context) PrivData)
decryptPrivData = fromMaybe M.empty . readish <$> gpgDecrypt privDataFile

makePrivDataDir :: IO ()
makePrivDataDir = createDirectoryIfMissing False privDataDir

privDataDir :: FilePath
privDataDir = "privdata"

privDataFile :: FilePath
privDataFile = privDataDir </> "privdata.gpg"

privDataLocal :: FilePath
privDataLocal = privDataDir </> "local"

gpgDecrypt :: FilePath -> IO String
gpgDecrypt f = ifM (doesFileExist f)
	( readProcess "gpg" ["--decrypt", f]
	, return ""
	)

gpgEncrypt :: FilePath -> String -> IO ()
gpgEncrypt f s = do
	encrypted <- writeReadProcessEnv "gpg"
		[ "--default-recipient-self"
		, "--armor"
		, "--encrypt"
		]
		Nothing
		(Just $ flip hPutStr s)
		Nothing
	viaTmp writeFile f encrypted
