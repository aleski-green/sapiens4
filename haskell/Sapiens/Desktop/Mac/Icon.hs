{-# LANGUAGE OverloadedStrings #-}
module Sapiens.Desktop.Mac.Icon where

import Control.Monad
import qualified Data.Text as T
import Foreign hiding (void, new)
import Sapiens.Desktop.Mac.ObjC
import System.FilePath

createIcon directory source = do
    loadFrameworks
    pool <- new "NSAutoreleasePool"
    image <- allocated "NSImage" >>= \o -> str (T.pack source) >>= obj1 o "initWithContentsOfFile:"
    when (image == nullPtr) $ ioError (userError "Cannot load workspace favicon SVG")
    forM_ [16,32,128,256,512] $ \dimension -> forM_ [1,2] $ \scale -> do
        let pixels = dimension * scale
        bitmap <- allocated "NSBitmapImageRep"
        color <- str "NSDeviceRGBColorSpace"
        selector <- sel "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:"
        representation <- callBitmap bitmap selector nullPtr (int pixels) (int pixels) (int 8) (int 4) (int 1) (int 0) color (int 0) (int 0)
        contextClass <- cls "NSGraphicsContext"
        void (obj0 contextClass "saveGraphicsState")
        context <- obj1 contextClass "graphicsContextWithBitmapImageRep:" representation
        void (obj1 contextClass "setCurrentContext:" context)
        drawSelector <- sel "drawInRect:fromRect:operation:fraction:"
        callDraw image drawSelector (fromIntegral pixels)
        void (obj0 contextClass "restoreGraphicsState")
        properties <- new "NSDictionary"
        dataValue <- obj2 representation "representationUsingType:properties:" (int 4) properties
        destination <- str (T.pack (directory </> ("icon_" ++ show dimension ++ "x" ++ show dimension ++ (if scale == 2 then "@2x" else "") ++ ".png")))
        result <- obj2 dataValue "writeToFile:atomically:" destination (int 1)
        when (result == nullPtr) $ ioError (userError "Could not write icon")
    void (obj0 pool "drain")
