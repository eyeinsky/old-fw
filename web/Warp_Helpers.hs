{-# OPTIONS_GHC -Wno-orphans #-}
module Warp_Helpers
  ( module Warp_Helpers
  , Warp.tlsSettings
  , Warp.TLSSettings
  ) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.ByteString as B
import qualified Data.HashMap.Strict as HM
import System.IO.Unsafe
import System.Environment

import qualified Control.Concurrent.Async as Async
import Control.Monad.Reader

import Network.Wai
import Network.Wai.Handler.Warp as Warp hiding (getPort)
import qualified Network.Wai.Handler.WarpTLS as Warp
import Network.HTTP.Types

import Common.Prelude
import URL

import Data.Hashable (Hashable)

getRequestBody :: Request -> IO BL.ByteString
getRequestBody req = BL.fromChunks <$> loop
   where
      loop = getRequestBodyChunk req >>= re
      re chunk = B.null chunk ? return [""] $ (chunk:) <$> loop

myRun :: URL.Port -> Handler -> IO ()
myRun (URL.Port port) f
   = runSettings (setPort (fromIntegral port) $ defaultSettings) $ \ r r' -> r' =<< f r

-- * Types

type Handler = Request -> IO Response
type Site = (Authority, IO Handler)

type AppName = String

type AppDef = (AppName, Authority -> IO Handler)
type Rule = (AppName, Authority, URL.Port)
type Https =  (AppDef, Rule, Warp.TLSSettings)

data Server = Server (Maybe Https) [AppDef] [Rule]

-- * Run http domains

runDomains :: URL.Port -> [Site] -> IO ()
runDomains bindPort sites = do
  pairs' <- initSites sites
  runSettings
    (mkPort bindPort)
    (\req respond -> let
        domain = fromJust $ getDomain req :: B.ByteString
        resp = snd <$> find ((== domain) . fst) pairs' :: Maybe Handler
      in respond =<< fromMaybe noDomain (($ req) <$> resp)
    )

mkPort port = setPort (fromIntegral $ port^.URL.un) $ defaultSettings

-- ** Helpers

initSites :: [Site] -> IO [(B.ByteString, Handler)]
initSites sites = forM sites initSite

initSite :: (Authority, IO Handler) -> IO (B.ByteString, Handler)
initSite (a, b) = (toHost a,) <$> b

toHost :: Authority -> B.ByteString
toHost authority = BL.toStrict . TLE.encodeUtf8 $ flip runReader () $ withoutSchema baseUrl
   where
     baseUrl = BaseURL (Proto "http") (view host authority) (view port authority)

noDomain :: Monad m => m Response
noDomain = return $ responseLBS status404 [] "No host"

getDomain :: Request -> Maybe B.ByteString
getDomain = lookup "Host" . requestHeaders

-- * Run web server

instance Hashable URL.Port where

runServer :: Server -> IO ()
runServer (Server https defs rules) = let
      join :: [(URL.Port, [Site])]
      join = do
         (name, app) <- defs
         (name', autho, bindPort) <- rules
         guard (name == name')
         return (bindPort, [(autho, app autho)])
      portSites :: [(URL.Port, [Site])]
      portSites = join & HM.fromListWith (<>) & HM.toList

      maybeHttpsIO = runHttps <$> https :: Maybe (IO ())
      httpIO = map (uncurry runDomains) portSites :: [IO ()]
      li = maybe httpIO (:httpIO) maybeHttpsIO :: [IO ()]
   in Async.mapConcurrently_ id li

runHttps :: Https -> IO ()
runHttps ((_, init), (_, auth, bindPort), tls) = do
  handler <- init auth
  Warp.runTLS tls (mkPort bindPort) (\req resp -> resp =<< handler req)

-- * Read TLS key and certificate path from environment

tlsSettingsEnvIO :: String -> String -> IO (Maybe Warp.TLSSettings)
tlsSettingsEnvIO cert key = do
  certPath <- lookupEnv cert
  keyPath <- lookupEnv key
  return $ Warp.tlsSettings <$> certPath <*> keyPath

tlsSettingsEnv :: String -> String -> Maybe Warp.TLSSettings
tlsSettingsEnv cert key = unsafePerformIO $ tlsSettingsEnvIO cert key
