module Web.Endpoint
  ( module Web.Endpoint
  , module Web.Response
  ) where


import Pr hiding (Reader, Writer, State)

import Control.Monad.State (get, put)
import Data.DList as DList
import HTTP.Common (ToPayload(..))

import qualified URL
import qualified Web as W
import Web (Browser)
import qualified HTTP.Header as Hdr
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Lazy as TL
import qualified Data.Text as T
import Render
import Identifiers (identifierSource)

import Web.Browser (browser)
import qualified JS
import DOM

import qualified Web.Response as Re
import Web.Response (UrlPath, renderUrlPath, appendSegment, appendSegments)
import qualified Network.Wai as Wai
import qualified Trie as Tr

import Text.Boomerang.Texts
import Text.Boomerang.TH
import Text.Boomerang hiding ((.~))

type I m r = W.WebT (ReaderT r m)
runI :: r -> W.Browser -> W.State -> I m r a -> m (a, W.State, W.Writer)
runI r br st m = m
  & W.runWebMT br st
  & flip runReaderT r

type Url = TL.Text

type Path = [Url]
type Urls = [Url]

type State = Urls
type Writer r = [(Url, T r)]
getWriter :: Url -> Writer r -> Maybe (T r)
getWriter p m = lookup p m
tellWriter u m = tell [(u, m)]

data T r where
  T :: RWST UrlPath (Writer r) State (I Identity r) (I IO r Re.AnyResponse) -> T r
unT (T a) = a
runT url m = runRWST (unT m) url $ (^.from strict) <$> identifierSource

-- * Build

eval
  :: W.HasBrowser r W.Browser
  => W.State -> UrlPath -> r -> T r -> [A r]
eval js_css_st0 up (r :: r) (m :: T r) = let
    b = r^.browser
    ((main, _ {-stUrls-}, subs), js_css_st1, js_css_w)
      = runIdentity (runI r b js_css_st0 (runT up m))

    self = (up, main, js_css_st1, js_css_w) :: A r

    re :: (Url, T r) -> [A r]
    re (url, m') = eval js_css_st1 (appendSegment up url) r m'

  in self : (re =<< subs) :: [A r]

type IIO r = I IO r Re.AnyResponse
type A r = (UrlPath, IIO r, W.State, W.Writer)

build :: W.HasBrowser r W.Browser => UrlPath -> r -> T r -> [(Path, IIO r, W.State, W.Writer)]
build domain r m = eval def domain r m <&> \a -> a & _1 %~ Re.toTextList

-- * Run

run :: Functor f => r -> Browser -> (Path, I f r Re.AnyResponse, W.State, W.Writer) -> f Re.AnyResponse
run r b (_, i_io, js_css_st, js_css_wr) = merge <$> res
  where
    res = runI r b js_css_st i_io
    merge (Re.HtmlDocument doc, st, wr) = Re.HtmlDocument $ collapse (js_css_wr <> wr) doc
    merge (x, _, _) = x

    collapse :: W.Writer -> W.Document -> W.Document
    collapse code doc
      = doc
      & add (W.style $ W.raw $ render $ code ^. W.cssCode)
      & add (W.script $ W.raw $ render $ putOnload $ code ^. W.jsCode)
      where add w = W.head' %~ (>> w)

-- * To handler

toHandler
  :: forall r. (W.HasBrowser r W.Browser, HasDynPath r Path)
  => UrlPath -> r -> T r -> Wai.Request -> IO (Maybe Re.AnyResponse)
toHandler domain conf site req = traverse (run conf' browser') res
  where
    app = build domain conf site
    found = Tr.lookupPrefix path $ Tr.fromList $ (\x -> (Pr.tail $ view _1 x, x)) <$> app
    (res, conf') = case found of
      Just (p, mv, _) -> (mv, conf & dynPath .~ p)
      _ -> (Nothing, conf)

    browser' = conf^.browser
    path = Wai.pathInfo req <&> (^.from strict)

-- * Dyn path

parseDyn
  :: (MonadReader s f, HasDynPath s [TL.Text])
  => Boomerang TextsError [T.Text] () (r :- ())
  -> f (Either TextsError r)
parseDyn parser = asks (view dynPath) <&> parseTexts parser . Pr.map (view (from lazy))

renderDyn :: Boomerang e [T.Text] () (r :- ()) -> r -> UrlPath -> UrlPath
renderDyn pp dt prefix = appendSegments prefix b
  where
    a = unparseTexts pp dt
    b = Pr.map (view $ from strict) $ fromJust a

-- * API

currentUrl = ask

api m = do
  (full, top) <- next'
  tellWriter top $ T $ m
  return full
  where
    next' = do
      top <- next
      full <- nextFullWith top
      return (full, top)

xhrPost m = do
  url :: UrlPath <- api m
  lift . W.js . fmap JS.Par . JS.func $ \data_ -> xhrJs "post" (JS.ulit $ renderUrlPath $ url) data_

pin :: (MonadWriter [(Url, T r)] m, MonadReader UrlPath m)
  => Url
  -> RWST UrlPath (Writer r) State (I Identity r) (I IO r Re.AnyResponse)
  -> m UrlPath
pin name m = do
  full <- nextFullWith name
  tellWriter name $ T $ m
  return full

page = api . return . return . Re.page

next = get >>= \(x : xs) -> put xs *> return x

nextFullWith :: MonadReader UrlPath m => Url -> m UrlPath
nextFullWith top = do
  prefix <- ask
  appendSegment prefix top & return

class HasDynPath s a | s -> a where
  dynPath :: Lens' s a
  {-# MINIMAL dynPath #-}
