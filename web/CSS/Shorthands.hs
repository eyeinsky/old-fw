module CSS.Shorthands where

import X.Prelude
import CSS.Internal
import CSS.Monad

import qualified Data.Text.Lazy as TL
import Language.Haskell.TH

import DOM.Core

$(let
    shorthand :: String -> DecsQ
    shorthand propName = [d| $(varP $ mkName name') = prop $(stringE propName) |]
      where
        x : xs = TL.splitOn "-" $ TL.pack propName
        f t = let (a, b) = TL.splitAt 1 t
          in TL.toUpper a <> b
        name' = TL.unpack $ TL.concat $ x : map f xs


    -- from left column of http://www.w3schools.com/cssref/default.asp
    li = filter (('@' /=) . head) $ words "align-content align-items align-self all animation animation-delay animation-direction animation-duration animation-fill-mode animation-iteration-count animation-name animation-play-state animation-timing-function backface-visibility background background-attachment background-blend-mode background-clip background-color background-image background-origin background-position background-repeat background-size border border-bottom border-bottom-color border-bottom-left-radius border-bottom-right-radius border-bottom-style border-bottom-width border-collapse border-color border-image border-image-outset border-image-repeat border-image-slice border-image-source border-image-width border-left border-left-color border-left-style border-left-width border-radius border-right border-right-color border-right-style border-right-width border-spacing border-style border-top border-top-color border-top-left-radius border-top-right-radius border-top-style border-top-width border-width bottom box-shadow box-sizing caption-side clear clip color column-count column-fill column-gap column-rule column-rule-color column-rule-style column-rule-width column-span column-width columns content counter-increment counter-reset cursor direction display empty-cells filter flex flex-basis flex-direction flex-flow flex-grow flex-shrink flex-wrap float font @font-face font-family font-size font-size-adjust font-stretch font-style font-variant font-weight grid grid-area grid-auto-columns grid-auto-flow grid-auto-rows grid-column grid-column-end grid-column-gap grid-column-start grid-gap grid-row grid-row-end grid-row-gap grid-row-start grid-template grid-template-areas grid-template-columns grid-template-rows hanging-punctuation height justify-content justify-items @keyframes left letter-spacing line-height list-style list-style-image list-style-position list-style-type margin margin-bottom margin-left margin-right margin-top max-height max-width @media min-height min-width nav-down nav-index nav-left nav-right nav-up opacity order outline outline-color outline-offset outline-style outline-width overflow overflow-x overflow-y padding padding-bottom padding-left padding-right padding-top page-break-after page-break-before page-break-inside perspective perspective-origin position quotes resize right tab-size table-layout text-align text-align-last text-decoration text-decoration-color text-decoration-line text-decoration-style text-indent text-justify text-overflow text-shadow text-transform top transform transform-origin transform-style transition transition-delay transition-duration transition-property transition-timing-function unicode-bidi vertical-align visibility white-space width word-break word-spacing word-wrap z-index"
  in concat <$> mapM shorthand li)

alpha a = rgba 0 0 0 a

hover = pseudo "hover"
before = pseudo "before"
after = pseudo "after"
focus = pseudo "focus"
active = pseudo "active"
visited = pseudo "visited"

nthChild :: Int -> CSSM () -> CSSM ()
nthChild n = pseudo str
  where
    n' = TL.pack (show n)
    str = "nth-child(" <> n' <> ")"

descendant = combinator Descendant
child = combinator Child
sibling = combinator Sibling
generalSibling = combinator GeneralSibling

anyTag :: Selector
anyTag = selFrom $ TagName "*"

anyChild :: CSSM () -> CSSM ()
anyChild = child ("*" :: TagName)
