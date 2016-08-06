{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module Reflex.Dom.Old
       ( MonadWidget
       , El
       , _el_element
       , addVoidAction
       , AttributeMap
       , Attributes (..)
       ) where

import Control.Arrow ((***))
import Control.Lens ((&), (.~))
import Control.Monad.Exception
import Control.Monad.Fix
import Control.Monad.IO.Class
import Control.Monad.Ref
import Data.Default
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Text as T
import Foreign.JavaScript.TH
import qualified GHCJS.DOM.Element as DOM
import Reflex
import Reflex.Dom.Builder.Class
import Reflex.Dom.Builder.Immediate
import Reflex.Dom.PerformEvent.Class
import Reflex.Dom.PostBuild.Class
import Reflex.Dom.Widget.Basic
import Reflex.Host.Class

--TODO: HasDocument is still not accounted for
type MonadWidget t m =
  ( DomBuilder t m
  , DomBuilderSpace m ~ GhcjsDomSpace
  , MonadFix m
  , MonadHold t m
  , MonadSample t (Performable m)
  , MonadReflexCreateTrigger t m
  , PostBuild t m
  , PerformEvent t m
  , MonadIO m
  , MonadIO (Performable m)
  , TriggerEvent t m
  , HasWebView m
  , HasWebView (Performable m)
  , MonadAsyncException m
  , MonadAsyncException (Performable m)
  , MonadRef m
  , Ref m ~ Ref IO
  , MonadRef (Performable m)
  , Ref (Performable m) ~ Ref IO
  )

type WidgetHost m = Performable m

type El = Element EventResult GhcjsDomSpace

_el_element :: El t -> RawElement GhcjsDomSpace
_el_element = _element_raw

addVoidAction :: MonadWidget t m => Event t (WidgetHost m ()) -> m ()
addVoidAction = performEvent_

type AttributeMap = Map String String

class Attributes m attrs where
  buildElement :: String -> attrs -> m a -> m (DOM.Element, a)

instance MonadWidget t m => Attributes m (Map String String) where
  buildElement elementTag attrs child = buildElementInternal elementTag child =<< addStaticAttributes attrs def

addStaticAttributes :: Applicative m => Map String String -> ElementConfig er t m -> m (ElementConfig er t m)
addStaticAttributes attrs cfg = do
  let initialAttrs = Map.fromList $ fmap (((,) Nothing . T.pack) *** T.pack) $ Map.toList attrs
  pure $ cfg & elementConfig_initialAttributes .~ initialAttrs

instance MonadWidget t m => Attributes m (Dynamic t (Map String String)) where
  buildElement elementTag attrs child = buildElementInternal elementTag child =<< addDynamicAttributes attrs def

addDynamicAttributes :: PostBuild t m => Dynamic t (Map String String) -> ElementConfig er t m -> m (ElementConfig er t m)
addDynamicAttributes attrs cfg = do
  modifyAttrs <- dynamicAttributesToModifyAttributes $ fmap (Map.fromList . fmap (T.pack *** T.pack) . Map.toList) attrs
  return $ cfg & elementConfig_modifyAttributes .~ modifyAttrs

buildElementInternal :: MonadWidget t m => String -> m a -> ElementConfig en t m -> m (DOM.Element, a)
buildElementInternal elementTag child cfg = do
  (e, result) <- element (T.pack elementTag) cfg child
  return (_element_raw e, result)
