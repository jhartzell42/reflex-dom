{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
#ifdef USE_TEMPLATE_HASKELL
{-# LANGUAGE TemplateHaskell #-}
#endif
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
module Reflex.Dom.Builder.Immediate
       ( EventTriggerRef (..)
       , ImmediateDomBuilderEnv (..)
       , ImmediateDomBuilderT (..)
       , runImmediateDomBuilderT
       , askDocument
       , askParent
       , askEvents
       , append
       , textNodeInternal
       , deleteBetweenExclusive
       , extractBetweenExclusive
       , deleteUpTo
       , extractUpTo
       , SupportsImmediateDomBuilder
       , collectUpTo
       , collectUpToGivenParent
       , EventFilterTriggerRef (..)
       , wrap
       , makeElement
       , GhcjsDomHandler (..)
       , GhcjsDomHandler1 (..)
       , GhcjsDomEvent (..)
       , GhcjsDomSpace
       , GhcjsEventFilter (..)
       , Pair1 (..)
       , Maybe1 (..)
       , GhcjsEventSpec (..)
       , ghcjsEventSpec_filters
       , ghcjsEventSpec_handler
       , GhcjsEventHandler (..)
#ifndef USE_TEMPLATE_HASKELL
       , phantom2
#endif
       , drawChildUpdate
       , mkHasFocus
       , insertBefore
       , EventType
       , defaultDomEventHandler
       , defaultDomWindowEventHandler
       , withIsEvent
       , showEventName
       , elementOnEventName
       , windowOnEventName
       , wrapDomEvent
       , subscribeDomEvent
       , wrapDomEventMaybe
       , wrapDomEventsMaybe
       , getKeyEvent
       , getMouseEventCoords
       , getTouchEvent
       , WindowConfig (..)
       , Window (..)
       , wrapWindow
       ) where

import Foreign.JavaScript.TH
import Reflex.Class as Reflex
import Reflex.Dom.Builder.Class
import Reflex.Dynamic
import Reflex.Host.Class
import qualified Reflex.Patch.DMap as PatchDMap
import qualified Reflex.Patch.DMapWithMove as PatchDMapWithMove
import Reflex.PerformEvent.Class
import Reflex.PostBuild.Class
import Reflex.TriggerEvent.Base hiding (askEvents)
import qualified Reflex.TriggerEvent.Base as TriggerEventT (askEvents)
import Reflex.TriggerEvent.Class

import Control.Concurrent
import Control.Lens hiding (element, ix)
import Control.Monad.Exception
import Control.Monad.Primitive
import Control.Monad.Reader
import Control.Monad.Ref
#ifndef USE_TEMPLATE_HASKELL
import Data.Functor.Contravariant (phantom)
#endif
import Data.Bitraversable
import Data.Default
import Data.Dependent.Map (DMap)
import qualified Data.Dependent.Map as DMap
import Data.Dependent.Sum
import Data.Functor.Compose
import Data.Functor.Constant
import Data.Functor.Misc
import Data.Functor.Product
import Data.IORef
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid hiding (Product)
import Data.Some (Some)
import qualified Data.Some as Some
import Data.Text (Text)
import qualified Data.Text as T
import qualified GHCJS.DOM as DOM
import GHCJS.DOM.RequestAnimationFrameCallback
import GHCJS.DOM.Document (Document, createDocumentFragmentUnchecked, createElementUnchecked, createElementNSUnchecked, createTextNodeUnchecked)
import GHCJS.DOM.Element (getScrollTop, removeAttribute, removeAttributeNS, setAttribute, setAttributeNS)
import qualified GHCJS.DOM.Element as Element
import qualified GHCJS.DOM.Event as Event
import GHCJS.DOM.EventM (EventM, event, on)
import qualified GHCJS.DOM.EventM as DOM
import qualified GHCJS.DOM.FileList as FileList
import qualified GHCJS.DOM.HTMLInputElement as Input
import qualified GHCJS.DOM.HTMLSelectElement as Select
import qualified GHCJS.DOM.HTMLTextAreaElement as TextArea
import GHCJS.DOM.MouseEvent
import qualified GHCJS.DOM.Touch as Touch
import qualified GHCJS.DOM.TouchEvent as TouchEvent
import qualified GHCJS.DOM.TouchList as TouchList
import GHCJS.DOM.Node (appendChild_, getOwnerDocumentUnchecked, getParentNodeUnchecked, setNodeValue, toNode)
import qualified GHCJS.DOM.Node as DOM (insertBefore_)
import GHCJS.DOM.Types
       (liftJSM, askJSM, runJSM, JSM, MonadJSM(..),
        FocusEvent, IsElement, IsEvent, IsNode, KeyboardEvent, Node,
        ToDOMString, TouchEvent, WheelEvent, uncheckedCastTo)
import qualified GHCJS.DOM.Types as DOM
import GHCJS.DOM.UIEvent
import qualified GHCJS.DOM.Window as Window
import Language.Javascript.JSaddle (call, eval)

import Reflex.Requester.Base
import Reflex.Requester.Class
import Foreign.JavaScript.Internal.Utils

data ImmediateDomBuilderEnv t
   = ImmediateDomBuilderEnv { _immediateDomBuilderEnv_document :: Document
                            , _immediateDomBuilderEnv_parent :: Node
                            , _immediateDomBuilderEnv_unreadyChildren :: IORef Word -- Number of children who still aren't fully rendered
                            , _immediateDomBuilderEnv_commitAction :: JSM () -- Action to take when all children are ready --TODO: we should probably get rid of this once we invoke it
                            }

newtype ImmediateDomBuilderT t m a = ImmediateDomBuilderT { unImmediateDomBuilderT :: ReaderT (ImmediateDomBuilderEnv t) (RequesterT t JSM Identity (TriggerEventT t m)) a }
  deriving (Functor, Applicative, Monad, MonadFix, MonadIO, MonadException, MonadAsyncException)

#ifndef __GHCJS__
instance MonadJSM m => MonadJSM (ImmediateDomBuilderT t m) where
    liftJSM' = ImmediateDomBuilderT . liftJSM'
#endif

instance PrimMonad m => PrimMonad (ImmediateDomBuilderT x m) where
  type PrimState (ImmediateDomBuilderT x m) = PrimState m
  primitive = lift . primitive

instance MonadTrans (ImmediateDomBuilderT t) where
  lift = ImmediateDomBuilderT . lift . lift . lift

instance (Reflex t, PrimMonad m) => DomRenderHook t (ImmediateDomBuilderT t m) where
  withRenderHook hook (ImmediateDomBuilderT a) = do
    e <- ImmediateDomBuilderT ask
    ImmediateDomBuilderT $ lift $ withRequesting $ \rsp -> do
      (x, req) <- lift $ runRequesterT (runReaderT a e) $ runIdentity <$> rsp
      return (ffor req $ \rm -> hook $ DMap.traverseWithKey (\_ r -> Identity <$> r) rm, x)
  requestDomAction = ImmediateDomBuilderT . lift . requestingIdentity
  requestDomAction_ = ImmediateDomBuilderT . lift . requesting_

{-# INLINABLE runImmediateDomBuilderT #-}
runImmediateDomBuilderT
  :: ( Reflex t
     , MonadFix m
     , PerformEvent t m
     , MonadReflexCreateTrigger t m
     , MonadJSM m
     , MonadJSM (Performable m)
     , MonadRef m
     , Ref m ~ IORef
     )
  => ImmediateDomBuilderT t m a
  -> ImmediateDomBuilderEnv t
  -> Chan [DSum (EventTriggerRef t) TriggerInvocation]
  -> m a
runImmediateDomBuilderT (ImmediateDomBuilderT a) env eventChan = flip runTriggerEventT eventChan $ do
  win <- DOM.currentWindowUnchecked
  rec (x, req) <- runRequesterT (runReaderT a env) rsp
      rsp <- performEventAsync $ ffor req $ \rm f -> liftJSM $ runInAnimationFrame win f $
        DMap.traverseWithKey (\_ r -> Identity <$> r) rm
  return x
  where
    runInAnimationFrame win f x = do
      rec cb <- newRequestAnimationFrameCallbackSync $ \_ -> do
            v <- synchronously x
            _ <- liftIO $ f v
            freeRequestAnimationFrameCallback cb
      _ <- Window.requestAnimationFrame win $ Just cb
      return ()

{-# INLINABLE askDocument #-}
askDocument :: Monad m => ImmediateDomBuilderT t m Document
askDocument = ImmediateDomBuilderT $ asks _immediateDomBuilderEnv_document

{-# INLINABLE askParent #-}
askParent :: Monad m => ImmediateDomBuilderT t m Node
askParent = ImmediateDomBuilderT $ asks _immediateDomBuilderEnv_parent

{-# INLINABLE askEvents #-}
askEvents :: Monad m => ImmediateDomBuilderT t m (Chan [DSum (EventTriggerRef t) TriggerInvocation])
askEvents = ImmediateDomBuilderT . lift . lift $ TriggerEventT.askEvents

localEnv :: Monad m => (ImmediateDomBuilderEnv t -> ImmediateDomBuilderEnv t) -> ImmediateDomBuilderT t m a -> ImmediateDomBuilderT t m a
localEnv f = ImmediateDomBuilderT . local f . unImmediateDomBuilderT

{-# INLINABLE append #-}
append :: (IsNode n, MonadJSM m) => n -> ImmediateDomBuilderT t m ()
append n = do
  p <- askParent
  liftJSM $ appendChild_ p $ Just n
  return ()

{-# INLINABLE textNodeInternal #-}
textNodeInternal :: (MonadJSM m, ToDOMString contents) => contents -> ImmediateDomBuilderT t m DOM.Text
textNodeInternal t = do
  doc <- askDocument
  n <- liftJSM $ createTextNodeUnchecked doc t
  append n
  return n

-- | s and e must both be children of the same node and s must precede e;
--   all nodes between s and e will be removed, but s and e will not be removed
deleteBetweenExclusive :: (MonadJSM m, IsNode start, IsNode end) => start -> end -> m ()
deleteBetweenExclusive s e = liftJSM $ do
  df <- createDocumentFragmentUnchecked =<< getOwnerDocumentUnchecked s
  extractBetweenExclusive df s e -- In many places in ImmediateDomBuilderT, we assume that things always have a parent; by adding them to this DocumentFragment, we maintain that invariant

-- | s and e must both be children of the same node and s must precede e; all
--   nodes between s and e will be moved into the given DocumentFragment, but s
--   and e will not be moved
extractBetweenExclusive :: (MonadJSM m, IsNode start, IsNode end) => DOM.DocumentFragment -> start -> end -> m ()
extractBetweenExclusive df s e = liftJSM $ do
  f <- eval $ T.unlines
    [ "(function(df,s,e){"
    , "  var x;"
    , "  for(;;){"
    , "    x = s.nextSibling;"
    , "    if(e===x) break;"
    , "    df.appendChild(x);"
    , "  }"
    , "})"
    ]
  void $ call f f (df, s, e)

-- | s and e must both be children of the same node and s must precede e;
--   s and all nodes between s and e will be removed, but e will not be removed
{-# INLINABLE deleteUpTo #-}
deleteUpTo :: (MonadJSM m, IsNode start, IsNode end) => start -> end -> m ()
deleteUpTo s e = do
  df <- createDocumentFragmentUnchecked =<< getOwnerDocumentUnchecked s
  extractUpTo df s e -- In many places in ImmediateDomBuilderT, we assume that things always have a parent; by adding them to this DocumentFragment, we maintain that invariant

extractUpTo :: (MonadJSM m, IsNode start, IsNode end) => DOM.DocumentFragment -> start -> end -> m ()
extractUpTo df s e = liftJSM $ do
  f <- eval $ T.unlines
    [ "(function(df,s,e){"
    , "  var x = s;"
    , "  var y;"
    , "  for(;;) {"
    , "    y = x.nextSibling;"
    , "    df.appendChild(x);"
    , "    if(e===y) break;"
    , "    x = y;"
    , "  }"
    , "})"
    ]
  void $ call f f (df, s, e)

type SupportsImmediateDomBuilder t m = (Reflex t, MonadJSM m, MonadHold t m, MonadFix m, MonadReflexCreateTrigger t m, MonadRef m, Ref m ~ Ref JSM, MonadAdjust t m, PrimMonad m)

{-# INLINABLE collectUpTo #-}
collectUpTo :: (MonadJSM m, IsNode start, IsNode end) => start -> end -> m DOM.DocumentFragment
collectUpTo s e = do
  currentParent <- getParentNodeUnchecked e -- May be different than it was at initial construction, e.g., because the parent may have dumped us in from a DocumentFragment
  collectUpToGivenParent currentParent s e

{-# INLINABLE collectUpToGivenParent #-}
collectUpToGivenParent :: (MonadJSM m, IsNode parent, IsNode start, IsNode end) => parent -> start -> end -> m DOM.DocumentFragment
collectUpToGivenParent currentParent s e = do
  doc <- getOwnerDocumentUnchecked currentParent
  df <- createDocumentFragmentUnchecked doc
  extractUpTo df s e
  return df

newtype EventFilterTriggerRef t er (en :: EventTag) = EventFilterTriggerRef (IORef (Maybe (EventTrigger t (er en))))

wrap :: forall m er t. SupportsImmediateDomBuilder t m => RawElement GhcjsDomSpace -> RawElementConfig er t (ImmediateDomBuilderT t m) -> ImmediateDomBuilderT t m (Element er GhcjsDomSpace t)
wrap e cfg = do
  events <- askEvents
  forM_ (_rawElementConfig_modifyAttributes cfg) $ \modifyAttrs -> requestDomAction_ $ ffor modifyAttrs $ imapM_ $ \(AttributeName mAttrNamespace n) mv -> case mAttrNamespace of
    Nothing -> maybe (removeAttribute e n) (setAttribute e n) mv
    Just ns -> maybe (removeAttributeNS e (Just ns) n) (setAttributeNS e (Just ns) n) mv
  eventTriggerRefs :: DMap EventName (EventFilterTriggerRef t er) <- liftJSM $ fmap DMap.fromList $ forM (DMap.toList $ _ghcjsEventSpec_filters $ _rawElementConfig_eventSpec cfg) $ \(en :=> GhcjsEventFilter f) -> do
    triggerRef <- liftIO $ newIORef Nothing
    _ <- elementOnEventName en e $ do
      evt <- DOM.event
      (flags, k) <- liftJSM $ f $ GhcjsDomEvent evt
      when (_eventFlags_preventDefault flags) $ withIsEvent en DOM.preventDefault
      case _eventFlags_propagation flags of
        Propagation_Continue -> return ()
        Propagation_Stop -> withIsEvent en DOM.stopPropagation
        Propagation_StopImmediate -> withIsEvent en DOM.stopImmediatePropagation
      mv <- liftJSM k --TODO: Only do this when the event is subscribed
      liftIO $ forM_ mv $ \v -> writeChan events [EventTriggerRef triggerRef :=> TriggerInvocation v (return ())]
    return $ en :=> EventFilterTriggerRef triggerRef
  es <- do
    let h :: GhcjsEventHandler er
        !h = _ghcjsEventSpec_handler $ _rawElementConfig_eventSpec cfg -- Note: this needs to be done strictly and outside of the newFanEventWithTrigger, so that the newFanEventWithTrigger doesn't retain the entire cfg, which can cause a cyclic dependency that the GC won't be able to clean up
    ctx <- askJSM
    newFanEventWithTrigger $ \(WrapArg en) t ->
      case DMap.lookup en eventTriggerRefs of
        Just (EventFilterTriggerRef r) -> do
          writeIORef r $ Just t
          return $ do
            writeIORef r Nothing
        Nothing -> (`runJSM` ctx) <$> (`runJSM` ctx) (elementOnEventName en e $ do
          evt <- DOM.event
          mv <- lift $ unGhcjsEventHandler h (en, GhcjsDomEvent evt)
          case mv of
            Nothing -> return ()
            Just v -> liftIO $ do
              --TODO: I don't think this is quite right: if a new trigger is created between when this is enqueued and when it fires, this may not work quite right
              ref <- newIORef $ Just t
              writeChan events [EventTriggerRef ref :=> TriggerInvocation v (return ())])
  return $ Element
    { _element_events = es
    , _element_raw = e
    }

{-# INLINABLE makeElement #-}
makeElement :: forall er t m a. SupportsImmediateDomBuilder t m => Text -> ElementConfig er t (ImmediateDomBuilderT t m) -> ImmediateDomBuilderT t m a -> ImmediateDomBuilderT t m ((Element er GhcjsDomSpace t, a), DOM.Element)
makeElement elementTag cfg child = do
  doc <- askDocument
  e <- liftJSM $ case cfg ^. namespace of
    Nothing -> createElementUnchecked doc (Just elementTag)
    Just ens -> createElementNSUnchecked doc (Just ens) (Just elementTag)
  ImmediateDomBuilderT $ iforM_ (cfg ^. initialAttributes) $ \(AttributeName mAttrNamespace n) v -> case mAttrNamespace of
    Nothing -> lift $ setAttribute e n v
    Just ans -> lift $ setAttributeNS e (Just ans) n v
  result <- flip localEnv child $ \env -> env
    { _immediateDomBuilderEnv_parent = toNode e
    }
  append e
  wrapped <- wrap e $ extractRawElementConfig cfg
  return ((wrapped, result), e)

newtype GhcjsDomHandler a b = GhcjsDomHandler { unGhcjsDomHandler :: a -> JSM b }

newtype GhcjsDomHandler1 a b = GhcjsDomHandler1 { unGhcjsDomHandler1 :: forall (x :: EventTag). a x -> JSM (b x) }

newtype GhcjsDomEvent en = GhcjsDomEvent { unGhcjsDomEvent :: EventType en }

data GhcjsDomSpace

instance DomSpace GhcjsDomSpace where
  type EventSpec GhcjsDomSpace = GhcjsEventSpec
  type RawTextNode GhcjsDomSpace = DOM.Text
  type RawElement GhcjsDomSpace = DOM.Element
  type RawFile GhcjsDomSpace = DOM.File
  type RawInputElement GhcjsDomSpace = DOM.HTMLInputElement
  type RawTextAreaElement GhcjsDomSpace = DOM.HTMLTextAreaElement
  type RawSelectElement GhcjsDomSpace = DOM.HTMLSelectElement
  addEventSpecFlags _ en f es = es
    { _ghcjsEventSpec_filters =
        let f' = Just . GhcjsEventFilter . \case
              Nothing -> \evt -> do
                mEventResult <- unGhcjsEventHandler (_ghcjsEventSpec_handler es) (en, evt)
                return (f mEventResult, return mEventResult)
              Just (GhcjsEventFilter oldFilter) -> \evt -> do
                (oldFlags, oldContinuation) <- oldFilter evt
                mEventResult <- oldContinuation
                let newFlags = oldFlags <> f mEventResult
                return (newFlags, return mEventResult)
        in DMap.alter f' en $ _ghcjsEventSpec_filters es
    }

newtype GhcjsEventFilter er en = GhcjsEventFilter (GhcjsDomEvent en -> JSM (EventFlags, JSM (Maybe (er en))))

data Pair1 (f :: k -> *) (g :: k -> *) (a :: k) = Pair1 (f a) (g a)

data Maybe1 f a = Nothing1 | Just1 (f a)

data GhcjsEventSpec er = GhcjsEventSpec
  { _ghcjsEventSpec_filters :: DMap EventName (GhcjsEventFilter er)
  , _ghcjsEventSpec_handler :: GhcjsEventHandler er
  }

newtype GhcjsEventHandler er = GhcjsEventHandler { unGhcjsEventHandler :: forall en. (EventName en, GhcjsDomEvent en) -> JSM (Maybe (er en)) }

#ifndef USE_TEMPLATE_HASKELL
phantom2 :: (Functor f, Contravariant f) => f a -> f b
phantom2 = phantom
{-# INLINE phantom2 #-}

ghcjsEventSpec_filters :: forall er . Lens' (GhcjsEventSpec er) (DMap EventName (GhcjsEventFilter er))
ghcjsEventSpec_filters f (GhcjsEventSpec a b) = (\a' -> GhcjsEventSpec a' b) <$> f a
{-# INLINE ghcjsEventSpec_filters #-}
ghcjsEventSpec_handler :: forall er en . Getter (GhcjsEventSpec er) ((EventName en, GhcjsDomEvent en) -> JSM (Maybe (er en)))
ghcjsEventSpec_handler f (GhcjsEventSpec _ (GhcjsEventHandler b)) = phantom2 (f b)
{-# INLINE ghcjsEventSpec_handler #-}
#endif

instance er ~ EventResult => Default (GhcjsEventSpec er) where
  def = GhcjsEventSpec
    { _ghcjsEventSpec_filters = mempty
    , _ghcjsEventSpec_handler = GhcjsEventHandler $ \(en, GhcjsDomEvent evt) -> do
        t :: DOM.EventTarget <- withIsEvent en $ Event.getTargetUnchecked evt --TODO: Rework this; defaultDomEventHandler shouldn't need to take this as an argument
        let e = uncheckedCastTo DOM.Element t
        runReaderT (defaultDomEventHandler e en) evt
    }

instance SupportsImmediateDomBuilder t m => DomBuilder t (ImmediateDomBuilderT t m) where
  type DomBuilderSpace (ImmediateDomBuilderT t m) = GhcjsDomSpace
  {-# INLINABLE textNode #-}
  textNode (TextNodeConfig initialContents mSetContents) = do
    n <- textNodeInternal initialContents
    mapM_ (requestDomAction_ . fmap (setNodeValue n . Just)) mSetContents
    return $ TextNode n
  {-# INLINABLE element #-}
  element elementTag cfg child = fst <$> makeElement elementTag cfg child
  {-# INLINABLE inputElement #-}
  inputElement cfg = do
    ((e, _), domElement) <- makeElement "input" (cfg ^. inputElementConfig_elementConfig) $ return ()
    let domInputElement = uncheckedCastTo DOM.HTMLInputElement domElement
    Input.setValue domInputElement $ Just (cfg ^. inputElementConfig_initialValue)
    v0 <- Input.getValueUnchecked domInputElement
    let getMyValue = fromMaybe "" <$> Input.getValue domInputElement
    valueChangedByUI <- requestDomAction $ liftJSM getMyValue <$ Reflex.select (_element_events e) (WrapArg Input)
    valueChangedBySetValue <- case _inputElementConfig_setValue cfg of
      Nothing -> return never
      Just eSetValue -> requestDomAction $ ffor eSetValue $ \v' -> do
        Input.setValue domInputElement $ Just v'
        getMyValue -- We get the value after setting it in case the browser has mucked with it somehow
    v <- holdDyn v0 $ leftmost
      [ valueChangedBySetValue
      , valueChangedByUI
      ]
    Input.setChecked domInputElement $ _inputElementConfig_initialChecked cfg
    checkedChangedByUI <- wrapDomEvent domInputElement (`on` Element.click) $ do
      Input.getChecked domInputElement
    checkedChangedBySetChecked <- case _inputElementConfig_setChecked cfg of
      Nothing -> return never
      Just eNewchecked -> requestDomAction $ ffor eNewchecked $ \newChecked -> do
        oldChecked <- Input.getChecked domInputElement
        Input.setChecked domInputElement newChecked
        return $ if newChecked /= oldChecked
                    then Just newChecked
                    else Nothing
    c <- holdDyn (_inputElementConfig_initialChecked cfg) $ leftmost
      [ fmapMaybe id checkedChangedBySetChecked
      , checkedChangedByUI
      ]
    let initialFocus = False --TODO: Is this correct?
    hasFocus <- holdDyn initialFocus $ leftmost
      [ False <$ Reflex.select (_element_events e) (WrapArg Blur)
      , True <$ Reflex.select (_element_events e) (WrapArg Focus)
      ]
    files <- holdDyn mempty <=< wrapDomEvent domInputElement (`on` Element.change) $ do
      mfiles <- Input.getFiles domInputElement
      let getMyFiles xs = fmap catMaybes . mapM (FileList.item xs) . flip take [0..] . fromIntegral =<< FileList.getLength xs
      maybe (return []) getMyFiles mfiles
    return $ InputElement
      { _inputElement_value = v
      , _inputElement_checked = uniqDyn c
      , _inputElement_checkedChange =  checkedChangedByUI
      , _inputElement_input = valueChangedByUI
      , _inputElement_hasFocus = hasFocus
      , _inputElement_element = e
      , _inputElement_raw = domInputElement
      , _inputElement_files = files
      }
  {-# INLINABLE textAreaElement #-}
  textAreaElement cfg = do --TODO
    ((e, _), domElement) <- makeElement "textarea" (cfg ^. textAreaElementConfig_elementConfig) $ return ()
    let domTextAreaElement = uncheckedCastTo DOM.HTMLTextAreaElement domElement
    TextArea.setValue domTextAreaElement $ Just (cfg ^. textAreaElementConfig_initialValue)
    v0 <- TextArea.getValueUnchecked domTextAreaElement
    let getMyValue = fromMaybe "" <$> TextArea.getValue domTextAreaElement
    valueChangedByUI <- requestDomAction $ liftJSM getMyValue <$ Reflex.select (_element_events e) (WrapArg Input)
    valueChangedBySetValue <- case _textAreaElementConfig_setValue cfg of
      Nothing -> return never
      Just eSetValue -> requestDomAction $ ffor eSetValue $ \v' -> do
        TextArea.setValue domTextAreaElement $ Just v'
        getMyValue -- We get the value after setting it in case the browser has mucked with it somehow
    v <- holdDyn v0 $ leftmost
      [ valueChangedBySetValue
      , valueChangedByUI
      ]
    hasFocus <- mkHasFocus e
    return $ TextAreaElement
      { _textAreaElement_value = v
      , _textAreaElement_input = valueChangedByUI
      , _textAreaElement_hasFocus = hasFocus
      , _textAreaElement_element = e
      , _textAreaElement_raw = domTextAreaElement
      }
  {-# INLINABLE selectElement #-}
  selectElement cfg child = do
    ((e, result), domElement) <- makeElement "select" (cfg ^. selectElementConfig_elementConfig) child
    let domSelectElement = uncheckedCastTo DOM.HTMLSelectElement domElement
    Select.setValue domSelectElement $ Just (cfg ^. selectElementConfig_initialValue)
    Just v0 <- Select.getValue domSelectElement
    let getMyValue = fromMaybe "" <$> Select.getValue domSelectElement
    valueChangedByUI <- requestDomAction $ liftJSM getMyValue <$ Reflex.select (_element_events e) (WrapArg Change)
    valueChangedBySetValue <- case _selectElementConfig_setValue cfg of
      Nothing -> return never
      Just eSetValue -> requestDomAction $ ffor eSetValue $ \v' -> do
        Select.setValue domSelectElement $ Just v'
        getMyValue -- We get the value after setting it in case the browser has mucked with it somehow
    v <- holdDyn v0 $ leftmost
      [ valueChangedBySetValue
      , valueChangedByUI
      ]
    hasFocus <- mkHasFocus e
    let wrapped = SelectElement
          { _selectElement_value = v
          , _selectElement_change = valueChangedByUI
          , _selectElement_hasFocus = hasFocus
          , _selectElement_element = e
          , _selectElement_raw = domSelectElement
          }
    return (wrapped, result)
  placeRawElement = append
  wrapRawElement = wrap
  notReadyUntil e = do
    eOnce <- headE e
    env <- ImmediateDomBuilderT ask
    let unreadyChildren = _immediateDomBuilderEnv_unreadyChildren env
    liftIO $ modifyIORef' unreadyChildren succ
    let ready = do
          old <- liftIO $ readIORef unreadyChildren
          let new = pred old
          liftIO $ writeIORef unreadyChildren $! new
          when (new == 0) $ _immediateDomBuilderEnv_commitAction env
    requestDomAction_ $ ready <$ eOnce
  notReady = do
    env <- ImmediateDomBuilderT ask
    let unreadyChildren = _immediateDomBuilderEnv_unreadyChildren env
    liftIO $ modifyIORef' unreadyChildren succ

data FragmentState
  = FragmentState_Unmounted
  | FragmentState_Mounted (DOM.Text, DOM.Text)

data ImmediateDomFragment = ImmediateDomFragment
  { _immediateDomFragment_document :: DOM.DocumentFragment
  , _immediateDomFragment_state :: IORef FragmentState
  }

extractFragment :: MonadJSM m => ImmediateDomFragment -> m ()
extractFragment fragment = do
  state <- liftIO $ readIORef $ _immediateDomFragment_state fragment
  case state of
    FragmentState_Unmounted -> return ()
    FragmentState_Mounted (before, after) -> do
      extractBetweenExclusive (_immediateDomFragment_document fragment) before after
      liftIO $ writeIORef (_immediateDomFragment_state fragment) FragmentState_Unmounted

instance SupportsImmediateDomBuilder t m => MountableDomBuilder t (ImmediateDomBuilderT t m) where
  type DomFragment (ImmediateDomBuilderT t m) = ImmediateDomFragment
  buildDomFragment w = do
    df <- createDocumentFragmentUnchecked =<< askDocument
    result <- flip localEnv w $ \env -> env
      { _immediateDomBuilderEnv_parent = toNode df
      }
    state <- liftIO $ newIORef FragmentState_Unmounted
    return (ImmediateDomFragment df state, result)
  mountDomFragment fragment setFragment = do
    parent <- askParent
    extractFragment fragment
    before <- textNodeInternal ("" :: Text)
    appendChild_ parent $ Just $ _immediateDomFragment_document fragment
    after <- textNodeInternal ("" :: Text)
    xs <- foldDyn (\new (previous, _) -> (new, Just previous)) (fragment, Nothing) setFragment
    requestDomAction_ $ ffor (updated xs) $ \(childFragment, Just previousFragment) -> do
      extractFragment previousFragment
      extractFragment childFragment
      insertBefore (_immediateDomFragment_document childFragment) after
      liftIO $ writeIORef (_immediateDomFragment_state childFragment) $ FragmentState_Mounted (before, after)
    liftIO $ writeIORef (_immediateDomFragment_state fragment) $ FragmentState_Mounted (before, after)

instance (Reflex t, MonadAdjust t m, MonadJSM m, MonadHold t m, MonadFix m, PrimMonad m) => MonadAdjust t (ImmediateDomBuilderT t m) where
  runWithReplace a0 a' = do
    initialEnv <- ImmediateDomBuilderT ask
    before <- textNodeInternal ("" :: Text)
    let parentUnreadyChildren = _immediateDomBuilderEnv_unreadyChildren initialEnv
    haveEverBeenReady <- liftIO $ newIORef False
    currentCohort <- liftIO $ newIORef (-1 :: Int) -- Equal to the cohort currently in the DOM
    let myCommitAction = do
          liftIO (readIORef haveEverBeenReady) >>= \case
            True -> return ()
            False -> do
              liftIO $ writeIORef haveEverBeenReady True
              old <- liftIO $ readIORef parentUnreadyChildren
              let new = pred old
              liftIO $ writeIORef parentUnreadyChildren $! new
              when (new == 0) $ _immediateDomBuilderEnv_commitAction initialEnv
    -- We draw 'after' in this roundabout way to avoid using MonadFix
    doc <- askDocument
    after <- createTextNodeUnchecked doc ("" :: Text)
    let drawInitialChild = do
          unreadyChildren <- liftIO $ newIORef 0
          let f = do
                result <- a0
                append after
                return result
          result <- runReaderT (unImmediateDomBuilderT f) $ initialEnv
            { _immediateDomBuilderEnv_unreadyChildren = unreadyChildren
            , _immediateDomBuilderEnv_commitAction = myCommitAction
            }
          liftIO $ readIORef unreadyChildren >>= \case
            0 -> writeIORef haveEverBeenReady True
            _ -> modifyIORef' parentUnreadyChildren succ
          return result
    a'' <- numberOccurrences a'
    (result0, result') <- ImmediateDomBuilderT $ lift $ runWithReplace drawInitialChild $ ffor a'' $ \(cohortId, child) -> do
      df <- createDocumentFragmentUnchecked doc
      unreadyChildren <- liftIO $ newIORef 0
      let commitAction = do
            c <- liftIO $ readIORef currentCohort
            when (c <= cohortId) $ do -- If a newer cohort has already been committed, just ignore this
              deleteBetweenExclusive before after
              insertBefore df after
              liftIO $ writeIORef currentCohort cohortId
              myCommitAction
      result <- runReaderT (unImmediateDomBuilderT child) $ initialEnv
        { _immediateDomBuilderEnv_parent = toNode df
        , _immediateDomBuilderEnv_unreadyChildren = unreadyChildren
        , _immediateDomBuilderEnv_commitAction = commitAction
        }
      liftIO (readIORef unreadyChildren) >>= \case
        0 -> liftJSM commitAction
        _ -> return () -- Whoever decrements it to 0 will handle it
      return result
    return (result0, result')
  traverseDMapWithKeyWithAdjust = do
    let updateChildUnreadiness (p :: PatchDMap k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v')) old = do
          let new :: forall a. k a -> ComposeMaybe (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v') a -> IO (ComposeMaybe (Constant (IORef (ChildReadyState k))) a)
              new k (ComposeMaybe m) = ComposeMaybe <$> case m of
                Nothing -> return Nothing
                Just (Compose (_, _, sRef, _)) -> do
                  readIORef sRef >>= \case
                    ChildReadyState_Ready -> return Nothing -- Delete this child, since it's ready
                    ChildReadyState_Unready _ -> do
                      writeIORef sRef $ ChildReadyState_Unready $ Just $ Some.This k
                      return $ Just $ Constant sRef
              delete _ (Constant sRef) = do
                writeIORef sRef $ ChildReadyState_Unready Nothing
                return $ Constant ()
          p' <- fmap PatchDMap $ DMap.traverseWithKey new $ unPatchDMap p
          _ <- DMap.traverseWithKey delete $ PatchDMap.getDeletions p old
          return $ applyAlways p' old
    hoistTraverseWithKeyWithAdjust traverseDMapWithKeyWithAdjust mapPatchDMap updateChildUnreadiness $ \placeholders lastPlaceholderRef (PatchDMap p) -> do
      phs <- liftIO $ readIORef placeholders
      forM_ (DMap.toList p) $ \(k :=> ComposeMaybe mv) -> do
        lastPlaceholder <- liftIO $ readIORef lastPlaceholderRef
        let nextPlaceholder = maybe lastPlaceholder snd $ Map.lookupGT (Some.This k) phs
        forM_ (Map.lookup (Some.This k) phs) $ \thisPlaceholder -> thisPlaceholder `deleteUpTo` nextPlaceholder
        forM_ mv $ \(Compose (df, _, _, _)) -> df `insertBefore` nextPlaceholder
      liftIO $ writeIORef placeholders $! fromMaybe phs $ apply (weakenPatchDMapWith (\(Compose (_, ph, _, _)) -> ph) $ PatchDMap p) phs
  traverseDMapWithKeyWithAdjustWithMove = do
    let updateChildUnreadiness (p :: PatchDMapWithMove k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v')) old = do
          let new :: forall a. k a -> PatchDMapWithMove.NodeInfo k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v') a -> IO (PatchDMapWithMove.NodeInfo k (Constant (IORef (ChildReadyState k))) a)
              new k = PatchDMapWithMove.nodeInfoMapFromM $ \case
                PatchDMapWithMove.From_Insert (Compose (_, _, sRef, _)) -> do
                  readIORef sRef >>= \case
                    ChildReadyState_Ready -> return PatchDMapWithMove.From_Delete
                    ChildReadyState_Unready _ -> do
                      writeIORef sRef $ ChildReadyState_Unready $ Just $ Some.This k
                      return $ PatchDMapWithMove.From_Insert $ Constant sRef
                PatchDMapWithMove.From_Delete -> return PatchDMapWithMove.From_Delete
                PatchDMapWithMove.From_Move fromKey -> return $ PatchDMapWithMove.From_Move fromKey
              deleteOrMove :: forall a. k a -> Product (Constant (IORef (ChildReadyState k))) (ComposeMaybe k) a -> IO (Constant () a)
              deleteOrMove _ (Pair (Constant sRef) (ComposeMaybe mToKey)) = do
                writeIORef sRef $ ChildReadyState_Unready $ Some.This <$> mToKey -- This will be Nothing if deleting, and Just if moving, so it works out in both cases
                return $ Constant ()
          p' <- fmap unsafePatchDMapWithMove $ DMap.traverseWithKey new $ unPatchDMapWithMove p
          _ <- DMap.traverseWithKey deleteOrMove $ PatchDMapWithMove.getDeletionsAndMoves p old
          return $ applyAlways p' old
    hoistTraverseWithKeyWithAdjust traverseDMapWithKeyWithAdjustWithMove mapPatchDMapWithMove updateChildUnreadiness $ \placeholders lastPlaceholderRef (p_ :: PatchDMapWithMove k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v')) -> do
      let p = unPatchDMapWithMove p_
      phsBefore <- liftIO $ readIORef placeholders
      lastPlaceholder <- liftIO $ readIORef lastPlaceholderRef
      let collectIfMoved :: forall a. k a -> PatchDMapWithMove.NodeInfo k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v') a -> JSM (Constant (Maybe DOM.DocumentFragment) a)
          collectIfMoved k e = do
            let mThisPlaceholder = Map.lookup (Some.This k) phsBefore -- Will be Nothing if this element wasn't present before
                nextPlaceholder = maybe lastPlaceholder snd $ Map.lookupGT (Some.This k) phsBefore
            case isJust $ getComposeMaybe $ PatchDMapWithMove._nodeInfo_to e of
              False -> do
                mapM_ (`deleteUpTo` nextPlaceholder) mThisPlaceholder
                return $ Constant Nothing
              True -> do
                Constant <$> mapM (`collectUpTo` nextPlaceholder) mThisPlaceholder
      collected <- DMap.traverseWithKey collectIfMoved p
      let !phsAfter = fromMaybe phsBefore $ apply (weakenPatchDMapWithMoveWith (\(Compose (_, ph, _, _)) -> ph) p_) phsBefore --TODO: Don't recompute this
      let placeFragment :: forall a. k a -> PatchDMapWithMove.NodeInfo k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v') a -> JSM (Constant () a)
          placeFragment k e = do
            let nextPlaceholder = maybe lastPlaceholder snd $ Map.lookupGT (Some.This k) phsAfter
            case PatchDMapWithMove._nodeInfo_from e of
              PatchDMapWithMove.From_Insert (Compose (df, _, _, _)) -> do
                df `insertBefore` nextPlaceholder
              PatchDMapWithMove.From_Delete -> do
                return ()
              PatchDMapWithMove.From_Move fromKey -> do
                Just (Constant mdf) <- return $ DMap.lookup fromKey collected
                mapM_ (`insertBefore` nextPlaceholder) mdf
            return $ Constant ()
      mapM_ (\(k :=> v) -> void $ placeFragment k v) $ DMap.toDescList p -- We need to go in reverse order here, to make sure the placeholders are in the right spot at the right time
      liftIO $ writeIORef placeholders $! phsAfter

data ChildReadyState k
   = ChildReadyState_Ready
   | ChildReadyState_Unready !(Maybe (Some k))
   deriving (Show, Read, Eq, Ord)

hoistTraverseWithKeyWithAdjust :: forall (k :: * -> *) v v' t m p.
  ( MonadAdjust t m
  , MonadHold t m
  , DMap.GCompare k
  , MonadIO m
  , MonadJSM m
  , PrimMonad m
  , MonadFix m
  , Patch (p k v)
  , PatchTarget (p k (Constant Int)) ~ DMap k (Constant Int)
  , Monoid (p k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v'))
  , Patch (p k (Constant Int))
  )
  => (forall vv vv'.
         (forall a. k a -> vv a -> RequesterT t JSM Identity (TriggerEventT t m) (vv' a))
      -> DMap k vv
      -> Event t (p k vv)
      -> RequesterT t JSM Identity (TriggerEventT t m) (DMap k vv', Event t (p k vv'))
     ) -- ^ The base monad's traversal
  -> (forall vv vv'. (forall a. vv a -> vv' a) -> p k vv -> p k vv') -- ^ A way of mapping over the patch type
  -> (p k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v') -> DMap k (Constant (IORef (ChildReadyState k))) -> IO (DMap k (Constant (IORef (ChildReadyState k))))) -- ^ Given a patch for the children DOM elements, produce a patch for the childrens' unreadiness state
  -> (IORef (Map.Map (Some.Some k) DOM.Text) -> IORef DOM.Text -> p k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v') -> JSM ()) -- ^ Apply a patch to the DOM
  -> (forall a. k a -> v a -> ImmediateDomBuilderT t m (v' a))
  -> DMap k v
  -> Event t (p k v)
  -> ImmediateDomBuilderT t m (DMap k v', Event t (p k v'))
hoistTraverseWithKeyWithAdjust base mapPatch updateChildUnreadiness applyDomUpdate_ (f :: forall a. k a -> v a -> ImmediateDomBuilderT t m (v' a)) (dm0 :: DMap k v) dm' = do
  initialEnv <- ImmediateDomBuilderT ask
  let parentUnreadyChildren = _immediateDomBuilderEnv_unreadyChildren initialEnv
  pendingChange :: IORef (DMap k (Constant (IORef (ChildReadyState k))), p k (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v')) <- liftIO $ newIORef mempty
  haveEverBeenReady <- liftIO $ newIORef False
  placeholders <- liftIO $ newIORef $ error "placeholders not yet initialized"
  lastPlaceholderRef <- liftIO $ newIORef $ error "lastPlaceholderRef not yet initialized"
  let applyDomUpdate p = do
        applyDomUpdate_ placeholders lastPlaceholderRef p
        markSelfReady
        liftIO $ writeIORef pendingChange $! mempty
      markSelfReady = do
        liftIO (readIORef haveEverBeenReady) >>= \case
          True -> return ()
          False -> do
            liftIO $ writeIORef haveEverBeenReady True
            old <- liftIO $ readIORef parentUnreadyChildren
            let new = pred old
            liftIO $ writeIORef parentUnreadyChildren $! new
            when (new == 0) $ _immediateDomBuilderEnv_commitAction initialEnv
      markChildReady :: IORef (ChildReadyState k) -> JSM ()
      markChildReady childReadyState = do
        liftIO (readIORef childReadyState) >>= \case
          ChildReadyState_Ready -> return ()
          ChildReadyState_Unready countedAt -> do
            liftIO $ writeIORef childReadyState ChildReadyState_Ready
            case countedAt of
              Nothing -> return ()
              Just (Some.This k) -> do -- This child has been counted as unready, so we need to remove it from the unready set
                (oldUnready, p) <- liftIO $ readIORef pendingChange
                when (not $ DMap.null oldUnready) $ do -- This shouldn't actually ever be null
                  let newUnready = DMap.delete k oldUnready
                  liftIO $ writeIORef pendingChange (newUnready, p)
                  when (DMap.null newUnready) $ do
                    applyDomUpdate p
  (children0, children') <- ImmediateDomBuilderT $ lift $ base (\k v -> drawChildUpdate initialEnv markChildReady $ f k v) dm0 dm'
  let processChild k (Compose (_, _, sRef, _)) = ComposeMaybe <$> do
        readIORef sRef >>= \case
          ChildReadyState_Ready -> return Nothing
          ChildReadyState_Unready _ -> do
            writeIORef sRef $ ChildReadyState_Unready $ Just $ Some.This k
            return $ Just $ Constant sRef
  initialUnready <- liftIO $ DMap.mapMaybeWithKey (\_ -> getComposeMaybe) <$> DMap.traverseWithKey processChild children0
  liftIO $ if DMap.null initialUnready
    then writeIORef haveEverBeenReady True
    else do
      modifyIORef' parentUnreadyChildren succ
      writeIORef pendingChange (initialUnready, mempty) -- The patch is always empty because it got applied implicitly when we ran the children the first time
  let result0 = DMap.map (\(Compose (_, _, _, v)) -> v) children0
      placeholders0 = weakenDMapWith (\(Compose (_, ph, _, _)) -> ph) children0
      result' = ffor children' $ mapPatch $ \(Compose (_, _, _, r)) -> r
  liftIO $ writeIORef placeholders $! placeholders0
  _ <- DMap.traverseWithKey (\_ (Compose (df, _, _, _)) -> Constant () <$ append df) children0
  liftIO . writeIORef lastPlaceholderRef =<< textNodeInternal ("" :: Text)
  requestDomAction_ $ ffor children' $ \p -> do
    (oldUnready, oldP) <- liftIO $ readIORef pendingChange
    newUnready <- liftIO $ updateChildUnreadiness p oldUnready
    let !newP = p <> oldP
    liftIO $ writeIORef pendingChange (newUnready, newP)
    when (DMap.null newUnready) $ do
      applyDomUpdate newP
  return (result0, result')

drawChildUpdate :: (MonadIO m, MonadJSM m)
  => ImmediateDomBuilderEnv t
  -> (IORef (ChildReadyState k) -> JSM ()) -- This will NOT be called if the child is ready at initialization time; instead, the ChildReadyState return value will be ChildReadyState_Ready
  -> ImmediateDomBuilderT t m (v' a)
  -> RequesterT t JSM Identity (TriggerEventT t m) (Compose ((,,,) DOM.DocumentFragment DOM.Text (IORef (ChildReadyState k))) v' a)
drawChildUpdate initialEnv markReady child = do
  childReadyState <- liftIO $ newIORef $ ChildReadyState_Unready Nothing
  unreadyChildren <- liftIO $ newIORef 0
  df <- createDocumentFragmentUnchecked $ _immediateDomBuilderEnv_document initialEnv
  (placeholder, result) <- runReaderT (unImmediateDomBuilderT $ (,) <$> textNodeInternal ("" :: Text) <*> child) $ initialEnv
    { _immediateDomBuilderEnv_parent = toNode df
    , _immediateDomBuilderEnv_unreadyChildren = unreadyChildren
    , _immediateDomBuilderEnv_commitAction = markReady childReadyState
    }
  u <- liftIO $ readIORef unreadyChildren
  when (u == 0) $ liftIO $ writeIORef childReadyState ChildReadyState_Ready
  return $ Compose (df, placeholder, childReadyState, result)

mkHasFocus :: (MonadHold t m, Reflex t) => Element er d t -> m (Dynamic t Bool)
mkHasFocus e = do
  let initialFocus = False --TODO: Actually get the initial focus of the element
  holdDyn initialFocus $ leftmost
    [ False <$ Reflex.select (_element_events e) (WrapArg Blur)
    , True <$ Reflex.select (_element_events e) (WrapArg Focus)
    ]

insertBefore :: (MonadJSM m, IsNode new, IsNode existing) => new -> existing -> m ()
insertBefore new existing = do
  p <- getParentNodeUnchecked existing
  DOM.insertBefore_ p (Just new) (Just existing) -- If there's no parent, that means we've been removed from the DOM; this should not happen if the we're removing ourselves from the performEvent properly

instance PerformEvent t m => PerformEvent t (ImmediateDomBuilderT t m) where
  type Performable (ImmediateDomBuilderT t m) = Performable m
  {-# INLINABLE performEvent_ #-}
  performEvent_ e = lift $ performEvent_ e
  {-# INLINABLE performEvent #-}
  performEvent e = lift $ performEvent e

instance PostBuild t m => PostBuild t (ImmediateDomBuilderT t m) where
  {-# INLINABLE getPostBuild #-}
  getPostBuild = lift getPostBuild

instance MonadReflexCreateTrigger t m => MonadReflexCreateTrigger t (ImmediateDomBuilderT t m) where
  {-# INLINABLE newEventWithTrigger #-}
  newEventWithTrigger = lift . newEventWithTrigger
  {-# INLINABLE newFanEventWithTrigger #-}
  newFanEventWithTrigger f = lift $ newFanEventWithTrigger f

instance (Monad m, MonadRef m, Ref m ~ Ref IO, MonadReflexCreateTrigger t m) => TriggerEvent t (ImmediateDomBuilderT t m) where
  {-# INLINABLE newTriggerEvent #-}
  newTriggerEvent = ImmediateDomBuilderT . lift . lift $ newTriggerEvent
  {-# INLINABLE newTriggerEventWithOnComplete #-}
  newTriggerEventWithOnComplete = ImmediateDomBuilderT . lift . lift $ newTriggerEventWithOnComplete
  {-# INLINABLE newEventWithLazyTriggerWithOnComplete #-}
  newEventWithLazyTriggerWithOnComplete f = ImmediateDomBuilderT . lift . lift $ newEventWithLazyTriggerWithOnComplete f

instance HasJSContext m => HasJSContext (ImmediateDomBuilderT t m) where
  type JSContextPhantom (ImmediateDomBuilderT t m) = JSContextPhantom m
  askJSContext = lift askJSContext

instance MonadRef m => MonadRef (ImmediateDomBuilderT t m) where
  type Ref (ImmediateDomBuilderT t m) = Ref m
  {-# INLINABLE newRef #-}
  newRef = lift . newRef
  {-# INLINABLE readRef #-}
  readRef = lift . readRef
  {-# INLINABLE writeRef #-}
  writeRef r = lift . writeRef r

instance MonadAtomicRef m => MonadAtomicRef (ImmediateDomBuilderT t m) where
  {-# INLINABLE atomicModifyRef #-}
  atomicModifyRef r = lift . atomicModifyRef r

instance (HasJS x m, ReflexHost t) => HasJS x (ImmediateDomBuilderT t m) where
  type JSX (ImmediateDomBuilderT t m) = JSX m
  liftJS = lift . liftJS

type family EventType en where
  EventType 'AbortTag = UIEvent
  EventType 'BlurTag = FocusEvent
  EventType 'ChangeTag = DOM.Event
  EventType 'ClickTag = MouseEvent
  EventType 'ContextmenuTag = MouseEvent
  EventType 'DblclickTag = MouseEvent
  EventType 'DragTag = MouseEvent
  EventType 'DragendTag = MouseEvent
  EventType 'DragenterTag = MouseEvent
  EventType 'DragleaveTag = MouseEvent
  EventType 'DragoverTag = MouseEvent
  EventType 'DragstartTag = MouseEvent
  EventType 'DropTag = MouseEvent
  EventType 'ErrorTag = UIEvent
  EventType 'FocusTag = FocusEvent
  EventType 'InputTag = DOM.Event
  EventType 'InvalidTag = DOM.Event
  EventType 'KeydownTag = KeyboardEvent
  EventType 'KeypressTag = KeyboardEvent
  EventType 'KeyupTag = KeyboardEvent
  EventType 'LoadTag = UIEvent
  EventType 'MousedownTag = MouseEvent
  EventType 'MouseenterTag = MouseEvent
  EventType 'MouseleaveTag = MouseEvent
  EventType 'MousemoveTag = MouseEvent
  EventType 'MouseoutTag = MouseEvent
  EventType 'MouseoverTag = MouseEvent
  EventType 'MouseupTag = MouseEvent
  EventType 'MousewheelTag = MouseEvent
  EventType 'ScrollTag = UIEvent
  EventType 'SelectTag = UIEvent
  EventType 'SubmitTag = DOM.Event
  EventType 'WheelTag = WheelEvent
  EventType 'BeforecutTag = DOM.Event
  EventType 'CutTag = DOM.Event
  EventType 'BeforecopyTag = DOM.Event
  EventType 'CopyTag = DOM.Event
  EventType 'BeforepasteTag = DOM.Event
  EventType 'PasteTag = DOM.Event
  EventType 'ResetTag = DOM.Event
  EventType 'SearchTag = DOM.Event
  EventType 'SelectstartTag = DOM.Event
  EventType 'TouchstartTag = TouchEvent
  EventType 'TouchmoveTag = TouchEvent
  EventType 'TouchendTag = TouchEvent
  EventType 'TouchcancelTag = TouchEvent

{-# INLINABLE defaultDomEventHandler #-}
defaultDomEventHandler :: IsElement e => e -> EventName en -> EventM e (EventType en) (Maybe (EventResult en))
defaultDomEventHandler e evt = fmap (Just . EventResult) $ case evt of
  Click -> return ()
  Dblclick -> getMouseEventCoords
  Keypress -> getKeyEvent
  Scroll -> getScrollTop e
  Keydown -> getKeyEvent
  Keyup -> getKeyEvent
  Mousemove -> getMouseEventCoords
  Mouseup -> getMouseEventCoords
  Mousedown -> getMouseEventCoords
  Mouseenter -> return ()
  Mouseleave -> return ()
  Focus -> return ()
  Blur -> return ()
  Change -> return ()
  Drag -> return ()
  Dragend -> return ()
  Dragenter -> return ()
  Dragleave -> return ()
  Dragover -> return ()
  Dragstart -> return ()
  Drop -> return ()
  Abort -> return ()
  Contextmenu -> return ()
  Error -> return ()
  Input -> return ()
  Invalid -> return ()
  Load -> return ()
  Mouseout -> return ()
  Mouseover -> return ()
  Select -> return ()
  Submit -> return ()
  Beforecut -> return ()
  Cut -> return ()
  Beforecopy -> return ()
  Copy -> return ()
  Beforepaste -> return ()
  Paste -> return ()
  Reset -> return ()
  Search -> return ()
  Selectstart -> return ()
  Touchstart -> getTouchEvent
  Touchmove -> getTouchEvent
  Touchend -> getTouchEvent
  Touchcancel -> getTouchEvent
  Mousewheel -> return ()
  Wheel -> return ()

{-# INLINABLE defaultDomWindowEventHandler #-}
defaultDomWindowEventHandler :: DOM.Window -> EventName en -> EventM DOM.Window (EventType en) (Maybe (EventResult en))
defaultDomWindowEventHandler w evt = fmap (Just . EventResult) $ case evt of
  Click -> return ()
  Dblclick -> getMouseEventCoords
  Keypress -> getKeyEvent
  Scroll -> Window.getScrollY w
  Keydown -> getKeyEvent
  Keyup -> getKeyEvent
  Mousemove -> getMouseEventCoords
  Mouseup -> getMouseEventCoords
  Mousedown -> getMouseEventCoords
  Mouseenter -> return ()
  Mouseleave -> return ()
  Focus -> return ()
  Blur -> return ()
  Change -> return ()
  Drag -> return ()
  Dragend -> return ()
  Dragenter -> return ()
  Dragleave -> return ()
  Dragover -> return ()
  Dragstart -> return ()
  Drop -> return ()
  Abort -> return ()
  Contextmenu -> return ()
  Error -> return ()
  Input -> return ()
  Invalid -> return ()
  Load -> return ()
  Mouseout -> return ()
  Mouseover -> return ()
  Select -> return ()
  Submit -> return ()
  Beforecut -> return ()
  Cut -> return ()
  Beforecopy -> return ()
  Copy -> return ()
  Beforepaste -> return ()
  Paste -> return ()
  Reset -> return ()
  Search -> return ()
  Selectstart -> return ()
  Touchstart -> getTouchEvent
  Touchmove -> getTouchEvent
  Touchend -> getTouchEvent
  Touchcancel -> getTouchEvent
  Mousewheel -> return ()
  Wheel -> return ()

{-# INLINABLE withIsEvent #-}
withIsEvent :: EventName en -> (IsEvent (EventType en) => r) -> r
withIsEvent en r = case en of
  Click -> r
  Dblclick -> r
  Keypress -> r
  Scroll -> r
  Keydown -> r
  Keyup -> r
  Mousemove -> r
  Mouseup -> r
  Mousedown -> r
  Mouseenter -> r
  Mouseleave -> r
  Focus -> r
  Blur -> r
  Change -> r
  Drag -> r
  Dragend -> r
  Dragenter -> r
  Dragleave -> r
  Dragover -> r
  Dragstart -> r
  Drop -> r
  Abort -> r
  Contextmenu -> r
  Error -> r
  Input -> r
  Invalid -> r
  Load -> r
  Mouseout -> r
  Mouseover -> r
  Select -> r
  Submit -> r
  Beforecut -> r
  Cut -> r
  Beforecopy -> r
  Copy -> r
  Beforepaste -> r
  Paste -> r
  Reset -> r
  Search -> r
  Selectstart -> r
  Touchstart -> r
  Touchmove -> r
  Touchend -> r
  Touchcancel -> r
  Mousewheel -> r
  Wheel -> r

showEventName :: EventName en -> String
showEventName en = case en of
  Abort -> "Abort"
  Blur -> "Blur"
  Change -> "Change"
  Click -> "Click"
  Contextmenu -> "Contextmenu"
  Dblclick -> "Dblclick"
  Drag -> "Drag"
  Dragend -> "Dragend"
  Dragenter -> "Dragenter"
  Dragleave -> "Dragleave"
  Dragover -> "Dragover"
  Dragstart -> "Dragstart"
  Drop -> "Drop"
  Error -> "Error"
  Focus -> "Focus"
  Input -> "Input"
  Invalid -> "Invalid"
  Keydown -> "Keydown"
  Keypress -> "Keypress"
  Keyup -> "Keyup"
  Load -> "Load"
  Mousedown -> "Mousedown"
  Mouseenter -> "Mouseenter"
  Mouseleave -> "Mouseleave"
  Mousemove -> "Mousemove"
  Mouseout -> "Mouseout"
  Mouseover -> "Mouseover"
  Mouseup -> "Mouseup"
  Mousewheel -> "Mousewheel"
  Scroll -> "Scroll"
  Select -> "Select"
  Submit -> "Submit"
  Wheel -> "Wheel"
  Beforecut -> "Beforecut"
  Cut -> "Cut"
  Beforecopy -> "Beforecopy"
  Copy -> "Copy"
  Beforepaste -> "Beforepaste"
  Paste -> "Paste"
  Reset -> "Reset"
  Search -> "Search"
  Selectstart -> "Selectstart"
  Touchstart -> "Touchstart"
  Touchmove -> "Touchmove"
  Touchend -> "Touchend"
  Touchcancel -> "Touchcancel"

{-# INLINABLE elementOnEventName #-}
elementOnEventName :: IsElement e => EventName en -> e -> EventM e (EventType en) () -> JSM (JSM ())
elementOnEventName en e = case en of
  Abort -> on e Element.abort
  Blur -> on e Element.blurEvent
  Change -> on e Element.change
  Click -> on e Element.click
  Contextmenu -> on e Element.contextMenu
  Dblclick -> on e Element.dblClick
  Drag -> on e Element.drag
  Dragend -> on e Element.dragEnd
  Dragenter -> on e Element.dragEnter
  Dragleave -> on e Element.dragLeave
  Dragover -> on e Element.dragOver
  Dragstart -> on e Element.dragStart
  Drop -> on e Element.drop
  Error -> on e Element.error
  Focus -> on e Element.focusEvent
  Input -> on e Element.input
  Invalid -> on e Element.invalid
  Keydown -> on e Element.keyDown
  Keypress -> on e Element.keyPress
  Keyup -> on e Element.keyUp
  Load -> on e Element.load
  Mousedown -> on e Element.mouseDown
  Mouseenter -> on e Element.mouseEnter
  Mouseleave -> on e Element.mouseLeave
  Mousemove -> on e Element.mouseMove
  Mouseout -> on e Element.mouseOut
  Mouseover -> on e Element.mouseOver
  Mouseup -> on e Element.mouseUp
  Mousewheel -> on e Element.mouseWheel
  Scroll -> on e Element.scroll
  Select -> on e Element.select
  Submit -> on e Element.submit
  Wheel -> on e Element.wheel
  Beforecut -> on e Element.beforeCut
  Cut -> on e Element.cut
  Beforecopy -> on e Element.beforeCopy
  Copy -> on e Element.copy
  Beforepaste -> on e Element.beforePaste
  Paste -> on e Element.paste
  Reset -> on e Element.reset
  Search -> on e Element.search
  Selectstart -> on e Element.selectStart
  Touchstart -> on e Element.touchStart
  Touchmove -> on e Element.touchMove
  Touchend -> on e Element.touchEnd
  Touchcancel -> on e Element.touchCancel

{-# INLINABLE windowOnEventName #-}
windowOnEventName :: EventName en -> DOM.Window -> EventM DOM.Window (EventType en) () -> JSM (JSM ())
windowOnEventName en e = case en of
  Abort -> on e Window.abort
  Blur -> on e Window.blurEvent
  Change -> on e Window.change
  Click -> on e Window.click
  Contextmenu -> on e Window.contextMenu
  Dblclick -> on e Window.dblClick
  Drag -> on e Window.drag
  Dragend -> on e Window.dragEnd
  Dragenter -> on e Window.dragEnter
  Dragleave -> on e Window.dragLeave
  Dragover -> on e Window.dragOver
  Dragstart -> on e Window.dragStart
  Drop -> on e Window.drop
  Error -> on e Window.error
  Focus -> on e Window.focusEvent
  Input -> on e Window.input
  Invalid -> on e Window.invalid
  Keydown -> on e Window.keyDown
  Keypress -> on e Window.keyPress
  Keyup -> on e Window.keyUp
  Load -> on e Window.load
  Mousedown -> on e Window.mouseDown
  Mouseenter -> on e Window.mouseEnter
  Mouseleave -> on e Window.mouseLeave
  Mousemove -> on e Window.mouseMove
  Mouseout -> on e Window.mouseOut
  Mouseover -> on e Window.mouseOver
  Mouseup -> on e Window.mouseUp
  Mousewheel -> on e Window.mouseWheel
  Scroll -> on e Window.scrollEvent
  Select -> on e Window.select
  Submit -> on e Window.submit
  Wheel -> on e Window.wheel
  Beforecut -> const $ return $ return () --TODO
  Cut -> const $ return $ return () --TODO
  Beforecopy -> const $ return $ return () --TODO
  Copy -> const $ return $ return () --TODO
  Beforepaste -> const $ return $ return () --TODO
  Paste -> const $ return $ return () --TODO
  Reset -> on e Window.reset
  Search -> on e Window.search
  Selectstart -> const $ return $ return () --TODO
  Touchstart -> on e Window.touchStart
  Touchmove -> on e Window.touchMove
  Touchend -> on e Window.touchEnd
  Touchcancel -> on e Window.touchCancel

{-# INLINABLE wrapDomEvent #-}
wrapDomEvent :: (TriggerEvent t m, MonadJSM m) => e -> (e -> EventM e event () -> JSM (JSM ())) -> EventM e event a -> m (Event t a)
wrapDomEvent el elementOnevent getValue = wrapDomEventMaybe el elementOnevent $ fmap Just getValue

{-# INLINABLE subscribeDomEvent #-}
subscribeDomEvent :: (EventM e event () -> JSM (JSM ()))
                  -> EventM e event (Maybe a)
                  -> Chan [DSum (EventTriggerRef t) TriggerInvocation]
                  -> EventTrigger t a
                  -> JSM (JSM ())
subscribeDomEvent elementOnevent getValue eventChan et = elementOnevent $ do
  mv <- getValue
  forM_ mv $ \v -> liftIO $ do
    --TODO: I don't think this is quite right: if a new trigger is created between when this is enqueued and when it fires, this may not work quite right
    etr <- newIORef $ Just et
    writeChan eventChan [EventTriggerRef etr :=> TriggerInvocation v (return ())]

{-# INLINABLE wrapDomEventMaybe #-}
wrapDomEventMaybe :: (TriggerEvent t m, MonadJSM m)
                  => e
                  -> (e -> EventM e event () -> JSM (JSM ()))
                  -> EventM e event (Maybe a)
                  -> m (Event t a)
wrapDomEventMaybe el elementOnevent getValue = do
  ctx <- askJSM
  newEventWithLazyTriggerWithOnComplete $ \trigger -> (`runJSM` ctx) <$> (`runJSM` ctx) (elementOnevent el $ do
    mv <- getValue
    forM_ mv $ \v -> liftIO $ trigger v $ return ())

{-# INLINABLE wrapDomEventsMaybe #-}
wrapDomEventsMaybe :: (MonadJSM m, MonadReflexCreateTrigger t m)
                   => e
                   -> (forall en. IsEvent (EventType en) => EventName en -> EventM e (EventType en) (Maybe (f en)))
                   -> (forall en. EventName en -> e -> EventM e (EventType en) () -> JSM (JSM ()))
                   -> ImmediateDomBuilderT t m (EventSelector t (WrapArg f EventName))
wrapDomEventsMaybe target handlers onEventName = do
  ctx <- askJSM
  eventChan <- askEvents
  e <- lift $ newFanEventWithTrigger $ \(WrapArg en) -> withIsEvent en
    (((`runJSM` ctx) <$>) . (`runJSM` ctx) . subscribeDomEvent (onEventName en target) (handlers en) eventChan)
  return $! e

{-# INLINABLE getKeyEvent #-}
getKeyEvent :: EventM e KeyboardEvent Int
getKeyEvent = do
  e <- event
  which <- getWhich e
  if which /= 0 then return which else do
    charCode <- getCharCode e
    if charCode /= 0 then return charCode else
      getKeyCode e

{-# INLINABLE getMouseEventCoords #-}
getMouseEventCoords :: EventM e MouseEvent (Int, Int)
getMouseEventCoords = do
  e <- event
  bisequence (getClientX e, getClientY e)

{-# INLINABLE getTouchEvent #-}
getTouchEvent :: EventM e TouchEvent TouchEventResult
getTouchEvent = do
  let touchResults = \case
        Nothing -> return []
        Just ts -> do
          n <- TouchList.getLength ts
          fmap catMaybes . forM (takeWhile (< n) [0..]) $ \ix -> do
            mt <- TouchList.item ts ix
            forM mt $ \t -> do
              identifier <- Touch.getIdentifier t
              screenX <- Touch.getScreenX t
              screenY <- Touch.getScreenY t
              clientX <- Touch.getClientX t
              clientY <- Touch.getClientY t
              pageX <- Touch.getPageX t
              pageY <- Touch.getPageY t
              return $ TouchResult
                { _touchResult_identifier = identifier
                , _touchResult_screenX = screenX
                , _touchResult_screenY = screenY
                , _touchResult_clientX = clientX
                , _touchResult_clientY = clientY
                , _touchResult_pageX = pageX
                , _touchResult_pageY = pageY
                }
  e <- event
  altKey <- TouchEvent.getAltKey e
  ctrlKey <- TouchEvent.getCtrlKey e
  shiftKey <- TouchEvent.getShiftKey e
  metaKey <- TouchEvent.getMetaKey e
  changedTouches <- touchResults =<< TouchEvent.getChangedTouches e
  targetTouches <- touchResults =<< TouchEvent.getTargetTouches e
  touches <- touchResults =<< TouchEvent.getTouches e
  return $ TouchEventResult
    { _touchEventResult_altKey = altKey
    , _touchEventResult_changedTouches = changedTouches
    , _touchEventResult_ctrlKey = ctrlKey
    , _touchEventResult_metaKey = metaKey
    , _touchEventResult_shiftKey = shiftKey
    , _touchEventResult_targetTouches = targetTouches
    , _touchEventResult_touches = touches
    }

instance MonadSample t m => MonadSample t (ImmediateDomBuilderT t m) where
  {-# INLINABLE sample #-}
  sample = lift . sample

instance MonadHold t m => MonadHold t (ImmediateDomBuilderT t m) where
  {-# INLINABLE hold #-}
  hold v0 v' = lift $ hold v0 v'
  {-# INLINABLE holdDyn #-}
  holdDyn v0 v' = lift $ holdDyn v0 v'
  {-# INLINABLE holdIncremental #-}
  holdIncremental v0 v' = lift $ holdIncremental v0 v'

data WindowConfig t = WindowConfig -- No config options yet

instance Default (WindowConfig t) where
  def = WindowConfig

data Window t = Window
  { _window_events :: EventSelector t (WrapArg EventResult EventName)
  , _window_raw :: DOM.Window
  }

wrapWindow :: (MonadJSM m, MonadReflexCreateTrigger t m) => DOM.Window -> WindowConfig t -> ImmediateDomBuilderT t m (Window t)
wrapWindow wv _ = do
  events <- wrapDomEventsMaybe wv (defaultDomWindowEventHandler wv) windowOnEventName
  return $ Window
    { _window_events = events
    , _window_raw = wv
    }

#ifdef USE_TEMPLATE_HASKELL
makeLenses ''GhcjsEventSpec
#endif
