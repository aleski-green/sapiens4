module Sapiens.Onboarding (main) where

import Prelude hiding (append, join)
import Control.Lazy as Lazy
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int as Int
import Effect (Effect)
import Effect.Aff (Aff, try, launchAff_)
import Effect.Class (liftEffect)
import Effect.Exception (message, throw)
import Sapiens.Runtime

mount :: Value -> Value -> Effect Value
mount pair status = do
  canvas <- call (global .! "document") "createElement" [value "canvas"]
  let state = value {stream:null,timer:null,generation:0}
      stop = do
        setField state "generation" $ int (state .! "generation") + 1
        cancelTimer $ state .! "timer"
        set state "timer" null
        when (boolean $ state .! "stream") do
          tracks <- call (state .! "stream") "getTracks" []
          for_ (array tracks) \track -> void $ call track "stop" []
        set state "stream" null
        video <- q "#qr-camera"
        when (boolean video) $ set video "srcObject" null
        scanner <- q "#scanner"
        when (boolean scanner) $ setField scanner "hidden" true
        button <- q "#scan-qr"
        when (boolean button) $ setField button "disabled" false
      feedback text = void $ invoke status [value text]
      readQR image width height limit = do
        let scale = min 1.0 $ limit / max width height
        setField canvas "width" $ Int.round $ width * scale
        setField canvas "height" $ Int.round $ height * scale
        context <- call canvas "getContext" [value "2d",value {willReadFrequently:true}]
        void $ call context "drawImage" [image,value 0,value 0,canvas .! "width",canvas .! "height"]
        pixels <- call context "getImageData" [value 0,value 0,canvas .! "width",canvas .! "height"]
        call (global .! "window" .! "RemoteVendor") "jsQR" [pixels .! "data",canvas .! "width",canvas .! "height"]
      pairQR qr = do
        invitation <- liftEffect $ call (global .! "window" .! "RemoteCode") "decode" [qr .! "data"]
        void $ await $ invoke pair [invitation]
      upload file = do
        unless (boolean $ global .! "window" .! "isSecureContext") $ liftEffect $ throw "Open this app over HTTPS."
        when (not (boolean file) || number (file .! "size") > 10485760.0) $ liftEffect $ throw "Choose a QR image smaller than 10 MB."
        url <- liftEffect $ call (global .! "URL") "createObjectURL" [file]
        result <- try do
          image <- liftEffect $ construct (global .! "Image") []
          liftEffect $ set image "src" url
          void $ await $ call image "decode" []
          when (number (image .! "naturalWidth") * number (image .! "naturalHeight") > 20000000.0) $ liftEffect $ throw "Image dimensions are too large."
          qr <- liftEffect $ readQR image (number $ image .! "naturalWidth") (number $ image .! "naturalHeight") 1600.0
          unless (boolean qr) $ liftEffect $ throw "No supported QR found in this image."
          pairQR qr
        liftEffect $ void $ call (global .! "URL") "revokeObjectURL" [url]
        case result of
          Left error -> liftEffect $ feedback $ message error
          Right _ -> pure unit
  q "#qr-file" >>= \node -> on node "change" false \event -> launchAff_ do
    outcome <- try $ upload $ at 0 $ array $ event .! "target" .! "files"
    liftEffect do
      case outcome of
        Left error -> feedback $ message error
        Right _ -> pure unit
      setField (event .! "target") "value" ""
  q "#stop-scan" >>= \node -> on node "click" false $ const stop
  q "#scan-qr" >>= \button -> on button "click" false \_ -> do
    stop
    let generation = state .! "generation"
    setField button "disabled" true
    feedback ""
    launchAff_ do
      result <- try do
        let devices = global .! "navigator" .! "mediaDevices"
        unless (boolean $ devices .! "getUserMedia") $ liftEffect $ throw "Camera unavailable. Upload a QR image."
        camera <- await $ call devices "getUserMedia" [value {video:{facingMode:{ideal:"environment"}},audio:false}]
        if not (same generation $ state .! "generation") then liftEffect do
          tracks <- call camera "getTracks" []
          for_ (array tracks) \track -> void $ call track "stop" []
        else do
          video <- liftEffect $ q "#qr-camera"
          liftEffect do
            set state "stream" camera
            set video "srcObject" camera
            prop "#scanner" "hidden" false
          void $ await $ call video "play" []
          let scan = Lazy.defer \_ -> when (same generation $ state .! "generation") do
                scanned <- try do
                  qr <- if number (video .! "readyState") >= 2.0 && boolean (video .! "videoWidth") then liftEffect $ readQR video (number $ video .! "videoWidth") (number $ video .! "videoHeight") 1000.0 else pure null
                  if boolean qr then liftEffect stop *> pairQR qr
                  else liftEffect $ delay 200 (launchAff_ scan) >>= set state "timer"
                case scanned of
                  Left error -> liftEffect $ stop *> feedback (message error)
                  Right _ -> pure unit
          scan
      case result of
        Left error -> liftEffect $ stop *> feedback (if field "name" (value error) == "NotAllowedError" then "Camera access is off. Upload a QR image." else message error)
        Right _ -> pure unit
  let hidden = callback \_ -> when (boolean $ global .! "document" .! "hidden") stop $> null
      pagehide = callback \_ -> stop $> null
  void $ call (global .! "document") "addEventListener" [value "visibilitychange",hidden]
  void $ call (global .! "window") "addEventListener" [value "pagehide",pagehide]
  pure $ value {stop:callback \_ -> stop $> null,dispose:callback \_ -> do
    stop
    void $ call (global .! "document") "removeEventListener" [value "visibilitychange",hidden]
    call (global .! "window") "removeEventListener" [value "pagehide",pagehide]}

main :: Effect Unit
main = setField (global .! "window") "RemoteOnboarding" {mount:callback \args -> mount (at 0 args) (at 1 args)}
