module Web.CSS.Monad where

import Prelude2
import qualified Data.Text.Lazy as TL

import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.Identity

import Web.Browser
import Web.CSS.Internal



-- * DSL setup

declareFields [d|
  data R = R
    { rSelector :: Selector
    , rBrowser :: Browser
    }
  |]

declareFields [d|
  data CSSW = CSSW
    { cSSWRules :: [Rule]
    , cSSWDecls :: [Declaration]
    }
  |]

type DM = Writer [Declaration]

type CSSM = WriterT CSSW (ReaderT R Identity)

-- * For export

type M = CSSM

run :: SelectorFrom a => Browser -> a -> CSSM () -> [Rule]
run b s m = runCSSM (R (selFrom s) b) m

rule :: SelectorFrom a => a -> DM () -> CSSM ()
rule s ds = tellRules [mkRule (selFrom s) (execWriter ds)]

prop
  :: (HasDecls w [Declaration], MonadWriter w m)
  => TL.Text -> Value -> m ()
prop k v = tellDecls [mkDeclaration k v]


tellRules rs = tell $ mempty & rules .~ rs
tellDecls ds = tell $ mempty & decls .~ ds

runCSSM :: R -> CSSM () -> [Rule]
runCSSM r m = r' : cssw^.rules
  where
    (_, cssw) = flip runReader r . runWriterT $ m
    r' = mkRule (r^.selector) (cssw^.decls)

runCSSM' :: R -> CSSM () -> CSSW
runCSSM' r m = snd . flip runReader r . runWriterT $ m

instance Monoid CSSW where
  mempty = CSSW [] []
  mappend a b = CSSW (a^.rules <> b^.rules) (a^.decls <> b^.decls)

apply :: (SimpleSelector -> SimpleSelector) -> Selector -> Selector
apply f s = go s
  where
    go :: Selector -> Selector
    go s = case s of
      Simple ss -> Simple (f ss)
      Combined op s ss -> Combined op s (f ss)

pseudo' :: TL.Text -> SimpleSelector -> SimpleSelector
pseudo' t s = s & pseudos %~ (p:)
  where p = Pseudo t

pseudo :: TL.Text -> CSSM () -> CSSM ()
pseudo t m = do
  conf <- ask
  let hoovered = apply (pseudo' t) (conf^.selector)
  tellRules $ runCSSM (R hoovered $ conf^.browser) m

combinator :: SOp -> SimpleSelector -> CSSM () -> CSSM ()
combinator c d m = do
  conf <- ask
  let r = R (Combined c (conf^.selector) d) (conf^.browser)
  tellRules $ runCSSM r m

-- * Keyframe monad

declareFields [d|
  data DeclW = DeclW { declWDecls :: [Declaration] }
  |]
-- ^ The 'decls' lens needed to reuse all the shorthands.

instance Monoid DeclW where
  mempty = DeclW mempty
  mappend a b = DeclW (a^.decls <> b^.decls)

type DeclM = WriterT DeclW (Reader Browser)

type KM = WriterT [KeyframeBlock] (Reader Browser)

keyframe :: Int -> DeclM () -> KM ()
keyframe n dm = do
  b :: Browser <- ask
  let dw = flip runReader b $ execWriterT dm :: DeclW
  tell [KeyframeBlock (KPercent n) (dw^.decls)]

keyframes :: TL.Text -> KM () -> CSSM ()
keyframes name km = do
  b :: Browser <- asks (view browser)
  let ks = flip runReader b $ execWriterT km :: [KeyframeBlock]
  tellRules [Keyframes name ks]