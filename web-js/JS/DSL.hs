{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE ExtendedDefaultRules #-}
module JS.DSL
  ( module JS.DSL
  , M, State(..), run
  , library, Function, funcPure, func, mkCode, Final

  -- * JS.Syntax
  , JS.Syntax.Conf
  , Statement(BareExpr, TryCatchFinally)
  , Expr(Undefined, Null, Par, Lit, Cast, AnonFunc, Raw, In, New, Await, Assign)
  , Attr(..)
  , Literal(..)
  , Code
  , call, call0, call1, (!.), (.!), ex
  ) where

import qualified Prelude as P
import Common.Prelude as P hiding (break)
import Data.String
import qualified Data.Set as S
import qualified Data.Hashable as H
import qualified Data.Text as TS
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Lens as TL
import qualified Data.Text.Lazy.IO as TL
import qualified Data.Aeson as A
import Data.Time
import Data.Default
import Data.Either
import Control.Arrow
import Control.Monad.Writer
import Control.Monad.State hiding (State)

import JS.Syntax hiding (Conf, Static)
import qualified JS.Syntax
import JS.DSL.Function as JS
import JS.DSL.MTL as JS
import Render

-- * Variable declarations

bind :: forall a b r. (Name -> Expr a -> Statement r) -> Expr a -> Name -> M r (Expr b)
bind decl expr name = do
  write $ decl name expr
  return $ EName name

newPrim :: (Name -> Expr a -> Statement r) -> Expr a -> M r (Expr a)
newPrim kw e = bind kw e =<< next

new, let_, const :: Expr a -> M r (Expr a)
new = newPrim VarDef
{-# DEPRECATED new "Use const, let_ or var instead." #-}
var = new
let_ = newPrim Let
const = newPrim Const

new' :: TS.Text -> Expr a -> M r (Expr a)
new' n e = bind Let e =<< pushName n

bare :: Expr a -> M r ()
bare e  = write $ BareExpr e

block    = let_    <=< blockExpr
block' n = new' n <=< blockExpr

-- * Comment

-- | Stopgap until syntax for block and single-line comments
comment :: TS.Text -> M r ()
comment text = bare $ ex $ "// " <> text

-- * Control flow

ternary :: Expr Bool -> Expr a -> Expr a -> Expr a
ternary = Ternary

ifmelse :: Expr Bool -> M r a -> Maybe (M r a) -> M r ()
ifmelse cond true mFalse = do
   trueCode <- mkCode true
   mElseCode <- maybe (return Nothing) (fmap Just . mkCode) mFalse
   write $ IfElse cond trueCode mElseCode

ifelse :: Expr Bool -> M r a -> M r a -> M r ()
ifelse c t e = ifmelse c t (Just e)

ifonly :: Expr Bool -> M r a -> M r ()
ifonly c t   = ifmelse c t Nothing

retrn :: Expr a -> M a ()
retrn e = write $ Return $ Cast e

empty :: M a ()
empty = write Empty

-- * try/catch

tryCatch :: M r () -> (Expr n -> M r ()) -> M r ()
tryCatch try catch = do
  try' <- mkCode try
  err <- next
  catch' <- mkCode $ catch (EName err)
  write $ TryCatchFinally try' [(err, catch')] Nothing

tryCatchFinally :: M r () -> (Expr n -> M r ()) -> M r () -> M r ()
tryCatchFinally try catch finally = do
  try' <- mkCode try
  err <- next
  catch' <- mkCode $ catch (EName err)
  finally' <- mkCode finally
  write $ TryCatchFinally try' [(err, catch')] (Just finally')

throw :: Expr a -> M r ()
throw e = write $ Throw e

-- * Swtich

-- m = match type
-- r = code block return type
type Case m r = Either (Code r) (Expr m, Code r)
type SwitchBodyM m r = WriterT [Case m r] (M r)

switch :: forall m r a. Expr m -> SwitchBodyM m r a -> M r ()
switch e m = do
  li :: [Case m r] <- execWriterT m
  let (def, cases') = partitionEithers li
  write $ Switch e cases' (case def of def' : _ -> Just def'; _ -> Nothing)

case_ :: Expr m -> M r a -> SwitchBodyM m r ()
case_ match code = do
  code' <- lift $ mkCode (code >> break)
  tell $ pure $ Right (match, code')

default_ :: M r a -> SwitchBodyM m r ()
default_ code = lift (mkCode code) >>= Left ^ pure ^ tell

-- * Class

type ClassBodyM = forall r. WriterT [ClassBodyPart] (M r) ()

-- ** Class declaration

class_ :: Name -> ClassBodyM -> M r (Expr b)
class_ name bodyParts = do
  bodyParts' <- execWriterT bodyParts
  write $ Class name Nothing bodyParts'
  return $ EName name

newClass :: ClassBodyM -> M r (Expr b)
newClass bodyParts = do
  name <- next
  class_ name bodyParts

extends :: Name -> ClassBodyM -> M r (Expr b)
extends what bodyParts = do
  bodyParts' <- execWriterT bodyParts
  name <- next
  write $ Class name (Just what) bodyParts'
  return $ EName name

-- ** Method and field helpers

constructor :: Function fexp => fexp -> ClassBodyM
constructor fexp = do
  (formalArgs, functionBody) <- lift $ bla fexp
  tell [ClassBodyMethod (Constructor formalArgs) functionBody]

methodMaker :: Function fexp => (Name -> [Name] -> ClassBodyMethodType) -> Name -> fexp -> ClassBodyM
methodMaker mm name fexp = do
  (formalArgs, functionBody) <- lift $ bla fexp
  tell [ClassBodyMethod (mm name formalArgs) functionBody]
  return ()

method, staticMethod, get, staticGet, set  :: Function fexp => Name -> fexp -> ClassBodyM
method = methodMaker InstanceMethod
staticMethod = methodMaker StaticMethod
get = methodMaker (\a _ -> Getter a)
staticGet = methodMaker (\a _ -> StaticGetter a)
set = methodMaker (\a [b] -> Setter a b)

-- * Loops

for :: Expr r -> M r a -> M r ()
for cond code = write . f =<< mkCode code
   where f = For Empty cond Empty

forIn :: Expr p -> (Expr n -> M r ()) -> M r ()
forIn expr mkBlock = do
   name <- next
   block <- mkCode $ mkBlock (EName name)
   write $ ForIn name expr block

forAwait :: Expr p -> (Expr n -> M r ()) -> M r ()
forAwait expr mkBlock = do
   name <- next
   block <- mkCode $ mkBlock (EName name)
   write $ ForAwait name expr block

forOf :: Expr p -> (Expr n -> M r ()) -> M r ()
forOf expr mkBlock = do
   name <- next
   block <- mkCode $ mkBlock (EName name)
   write $ ForOf name expr block

while :: Expr r -> M r a -> M r ()
while cond code = write . f =<< mkCode code
   where f = While cond

break = write $ Break Nothing
continue = write $ Continue Nothing

-- * Assignment operator

-- | Shorthands for assignment statement
infixr 4 .=
(.=) :: Expr a -> Expr b -> M r ()
lhs .= rhs = write $ BareExpr $ lhs `Assign` rhs

-- | @infixr 0@ shorthand for assignment statement -- for combining
-- with the dollar operator (@$@).
infixr 0 .=$
(.=$) = (.=)

-- | Compound assignments in statement form
a .+= b = a .= (a + b)
a .-= b = a .= (a - b)
a .*= b = a .= (a * b)
a ./= b = a .= (a P./ b)

--

type Promise = Expr

await :: Expr a -> JS.M r (Expr a)
await = let_ . JS.Syntax.Await
{-# DEPRECATED await "Use const $ Await instead." #-}

-- | Make a promise out of a function through async
promise :: Function f => f -> JS.M r (Promise b)
promise f = call0 <$> async f

blockExpr :: M r a -> M r (Expr r)
blockExpr = fmap (AnonFunc Nothing []) . mkCode
-- ^ Writes argument 'M r a' to writer and returns a callable name

arguments = ex "arguments"

-- * Typed functions

newf, async, generator :: Function f => f -> M r (Expr (Type f))
newf = let_ <=< func AnonFunc
async = let_ <=< func Async
generator = let_ <=< func Generator

newf' :: Function f => TS.Text -> f -> M r (Expr (Type f))
newf' n = new' n <=< func AnonFunc

fn :: (Function f, Back (Expr (Type f))) => f -> M r (Convert (Expr (Type f)))
fn f = newf f <&> convert []
fn' n f = newf' n f <&> convert []

async_ :: (Function f, Back (Expr (Type f))) => f -> M r (Convert (Expr (Type f)))
async_ f = async f <&> convert []

a !/ b = call0 (a !. b)
a !// b = call1 (a !. b)

math name = ex "Math" !. name

-- ** Operators (untyped)

typeOf :: Expr a -> Expr String
typeOf = Op . OpUnary TypeOf

e1 .==  e2 = Op $ OpBinary   Eq e1 e2
e1 .=== e2 = Op $ OpBinary  EEq e1 e2
e1 .!=  e2 = Op $ OpBinary  NEq e1 e2
e1 .!== e2 = Op $ OpBinary NEEq e1 e2

infix 4 .==
infix 4 .===
infix 4 .!=
infix 4 .!==

e1 .&& e2 = Op $ OpBinary And e1 e2
e1 .|| e2 = Op $ OpBinary Or e1 e2

infixr 3 .&&
infixr 2 .||

e1 .<  e2  = Op $ OpBinary Lt e1 e2
e1 .>  e2  = Op $ OpBinary Gt e1 e2
e1 .<= e2 = Op $ OpBinary LEt e1 e2
e1 .>= e2 = Op $ OpBinary GEt e1 e2

infix 4 .<
infix 4 .>
infix 4 .<=
infix 4 .>=

e1 % e2 = Op $ OpBinary Modulus e1 e2

infixl 7  %

e1 `instanceof` e2 = Op $ OpBinary Instanceof e1 e2

-- * Literals

class ToExpr a where lit :: a -> Expr b
instance ToExpr (Expr a) where lit = Cast
instance ToExpr Int      where lit = Lit . Integer . toInteger
instance ToExpr Integer  where lit = Lit . Integer
instance ToExpr Rational where lit = Lit . Double . fromRational
instance ToExpr Double   where lit = Lit . Double
instance ToExpr Bool     where lit = Lit . Bool
instance ToExpr TS.Text  where lit = Lit . String
instance ToExpr TL.Text  where lit = lit . TL.toStrict
instance ToExpr String   where lit = lit . TL.pack
instance ToExpr A.Value where
  lit v = A.encode v ^. TL.utf8 & Raw

instance {-# OVERLAPPABLE #-} ToExpr a => ToExpr [a] where
   lit = Lit . Array . map lit

-- ** Object

instance ToExpr v => ToExpr [(TS.Text, v)] where
   lit li = Lit $ Object $ map f li
      where f (k, v) = (Left $ Name k, lit v)
ck f = lit . map (first f)
instance ToExpr v => ToExpr [(TL.Text, v)] where
   lit = ck TL.toStrict
instance ToExpr v => ToExpr [(String, v)] where
  lit = ck TS.pack
instance ToExpr v => ToExpr [(Expr k, v)] where
   lit li = Lit $ Object $ map f li
      where f (k, v) = (Right $ Cast k, lit v)


instance IsString (Expr a) where
   fromString s = lit s

instance ToExpr a => ToExpr (Maybe a) where
  lit = maybe Null lit

instance ToExpr UTCTime where
  lit t = lit $ formatTime defaultTimeLocale format t
    where
      format = iso8601DateFormat (Just "%H:%M:%S%QZ")
      -- Prints ISO8601, e.g "2019-11-04T15:42:18.608734Z"

instance ToExpr Day where
  lit t = lit $ show t

data RegExp
regex str opts = Lit $ RegExp str opts :: Expr RegExp

toRegex :: Expr a -> TS.Text -> Expr RegExp
toRegex str mod = call (ex "RegExp") [str, lit mod]

not :: Expr Bool -> Expr Bool
not = Op . OpUnary Not

(!-) :: ToExpr b => Expr a -> b -> Expr c
(!-) a b = Arr a (lit b)

instance Num (Expr a) where
   fromInteger s = lit s
   e1 + e2 = Op $ OpBinary Plus e1 e2
   e1 - e2 = Op $ OpBinary Minus e1 e2
   e1 * e2 = Op $ OpBinary Mult e1 e2
   negate n = 0 - n
   abs = call1 (math "abs")
   signum = call1 (math "sign")
instance Fractional (Expr a) where
   fromRational s = lit s
   e1 / e2 = Op $ OpBinary Div e1 e2

pr :: M r a -> IO ()
pr = TL.putStrLn . render (Indent 2) . snd . fst . run fresh used lib
  where
    State fresh used lib = def

-- * Modules

lib :: M r (Expr a) -> M r (Expr a)
lib mcode = let
    State fresh used lib = def
    codeText = render Minify . snd . fst . run fresh used lib $ mcode -- fix: take config from somewhere
    codeHash = H.hash codeText
    nameExpr = EName $ Name $ "h" <> TS.replace "-" "_" (TL.toStrict $ tshow codeHash)
  in do
  set <- gets (^.library)
  when (P.not $ codeHash `S.member` set) $ do
    f <- mcode
    nameExpr .= f
    modify (library %~ S.insert codeHash)
  return nameExpr

instance Render (M r a) where
  type Conf (M r a) = JS.Syntax.Conf
  renderM = renderM . snd . fst . run fresh used lib
    where
      State fresh used lib = def

-- * Semigroup and monoid instances

instance {-# OVERLAPPABLE #-} Semigroup (Expr [a]) where
  a <> b = a !// "concat" $ b
instance {-# OVERLAPPABLE #-} Monoid (Expr [a]) where
  mempty = Lit $ Array []

data Object

instance {-# OVERLAPPABLE #-} Semigroup (Expr Object) where
  a <> b = a !// "concat" $ b
instance {-# OVERLAPPABLE #-} Monoid (Expr Object) where
  mempty = Lit $ Object []

instance {-# OVERLAPPABLE #-} Semigroup (Expr a) where
  a <> b = call (ex "Object" !. "assign") [mempty :: Expr Object, Cast a, Cast b]
instance {-# OVERLAPPABLE #-} Monoid (Expr a) where
  mempty = Lit $ Object []

instance {-# OVERLAPPABLE #-} Semigroup (Expr String) where
  a <> b = a + b
instance Monoid (Expr String) where
  mempty = ""

instance Floating (Expr a) where
  pi = lit pi
  exp = todo
  log = todo
  sin = todo
  cos = todo
  asin = todo
  acos = todo
  atan n = call1 (math "atan") n
  sinh = todo
  cosh = todo
  asinh = todo
  acosh = todo
  atanh = todo
