module Propellor.Property.Postfix where

import Propellor
import qualified Propellor.Property.Apt as Apt
import Propellor.Property.File
import qualified Propellor.Property.Service as Service

import qualified Data.Map as M
import Data.List
import Data.Char

installed :: Property
installed = Apt.serviceInstalledRunning "postfix"

restarted :: Property
restarted = Service.restarted "postfix"

reloaded :: Property
reloaded = Service.reloaded "postfix"

-- | Configures postfix as a satellite system, which 
-- relays all mail through a relay host, which defaults to smtp.domain. 
--
-- The smarthost may refuse to relay mail on to other domains, without
-- futher coniguration/keys. But this should be enough to get cron job
-- mail flowing to a place where it will be seen.
satellite :: Property
satellite = check (not <$> mainCfIsSet "relayhost") setup
	`requires` installed
  where
	setup = trivial $ property "postfix satellite system" $ do
		hn <- asks hostName
		let (_, domain) = separate (== '.') hn
		ensureProperties 
			[ Apt.reConfigure "postfix"
				[ ("postfix/main_mailer_type", "select", "Satellite system")
				, ("postfix/root_address", "string", "root")
				, ("postfix/destinations", "string", " ")
				, ("postfix/mailname", "string", hn)
				]
			, mainCf ("relayhost", domain)
				`onChange` reloaded
			]

-- | Sets up a file by running a property (which the filename is passed
-- to). If the setup property makes a change, postmap will be run on the
-- file, and postfix will be reloaded.
mappedFile :: FilePath -> (FilePath -> Property) -> Property
mappedFile f setup = setup f
	`onChange` cmdProperty "postmap" [f]

-- | Run newaliases command, which should be done after changing
-- /etc/aliases.
newaliases :: Property
newaliases = trivial $ cmdProperty "newaliases" []

-- | The main config file for postfix.
mainCfFile :: FilePath
mainCfFile = "/etc/postfix/main.cf"

-- | Sets a main.cf name=value pair. Does not reload postfix immediately.
mainCf :: (String, String) -> Property
mainCf (name, value) = check notset set
		`describe` ("postfix main.cf " ++ setting)
  where
	setting = name ++ "=" ++ value
	notset = (/= Just value) <$> getMainCf name
	set = cmdProperty "postconf" ["-e", setting]

-- | Gets a man.cf setting.
getMainCf :: String -> IO (Maybe String)
getMainCf name = parse . lines <$> readProcess "postconf" [name]
  where
	parse (l:_) = Just $ 
		case separate (== '=') l of
			(_, (' ':v)) -> v
			(_, v) -> v
	parse [] = Nothing

-- | Checks if a main.cf field is set. A field that is set to "" 
-- is considered not set.
mainCfIsSet :: String -> IO Bool
mainCfIsSet name = do
	v <- getMainCf name
	return $ v /= Nothing && v /= Just ""

-- | Parses main.cf, and removes any initial configuration lines that are
-- overridden to other values later in the file.
--
-- For example, to add some settings, removing any old settings:
--
-- > mainCf `File.containsLines`
-- >	[ "# I like bars."
-- >	, "foo = bar"
-- >	] `onChange` dedupMainCf
--
-- Note that multiline configurations that continue onto the next line
-- are not currently supported.
dedupMainCf :: Property
dedupMainCf = fileProperty "postfix main.cf dedupped" dedupCf mainCfFile

dedupCf :: [String] -> [String]
dedupCf ls =
	let parsed = map parse ls
	in dedup [] (keycounts $ rights parsed) parsed
  where	
	parse l
		| "#" `isPrefixOf` l = Left l
		| "=" `isInfixOf` l = 
			let (k, v) = separate (== '=') l
			in Right ((filter (not . isSpace) k), v)
		| otherwise = Left l
	fmt k v = k ++ " =" ++ v

	keycounts = M.fromListWith (+) . map (\(k, _v) -> (k, (1 :: Integer)))

	dedup c _ [] = reverse c
	dedup c kc ((Left v):rest) = dedup (v:c) kc rest
	dedup c kc ((Right (k, v)):rest) = case M.lookup k kc of
		Just n | n > 1 -> dedup c (M.insert k (n - 1) kc) rest
		_ -> dedup (fmt k v:c) kc rest
