module Web.CSS where

import X.Prelude
import Web.Monad
import CSS

reset = do
  cssRule (tagSelector "html") (boxSizing "border-box")
  cssRule (tagSelector "ul") (listStyle "none")
  cssRule anyTag $ do
    boxSizing "inherit"
    zero
  where
    zero = do
      padding $ px 0
      margin $ px 0
