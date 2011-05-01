{-# LANGUAGE CPP, UnicodeSyntax, NoImplicitPrelude, DeriveDataTypeable #-}

#ifdef HAS_EVENT_MANAGER
{-# LANGUAGE ForeignFunctionInterface #-}
#endif

module System.USB.Base where

--------------------------------------------------------------------------------
-- Imports
--------------------------------------------------------------------------------

-- from base:
import Prelude               ( Num, (+), (-), (*), Integral, fromIntegral, div
                             , Enum, fromEnum, error
                             )
import Foreign.C.Types       ( CUChar, CInt, CUInt )
import Foreign.C.String      ( CStringLen )
import Foreign.Marshal.Alloc ( alloca )
import Foreign.Marshal.Array ( peekArray, allocaArray )
import Foreign.Storable      ( Storable, peek, peekElemOff )
import Foreign.Ptr           ( Ptr, castPtr, plusPtr, nullPtr )
import Foreign.ForeignPtr    ( ForeignPtr, newForeignPtr, withForeignPtr)
import Control.Applicative   ( liftA2 )
import Control.Exception     ( Exception, throwIO, bracket, bracket_, onException, assert )
import Control.Monad         ( Monad, (>>=), (=<<), return, when, forM )
import Control.Arrow         ( (&&&) )
import Data.Function         ( ($), flip, on )
import Data.Functor          ( Functor, fmap, (<$>) )
import Data.Data             ( Data )
import Data.Typeable         ( Typeable )
import Data.Maybe            ( Maybe(Nothing, Just), maybe, fromMaybe )
import Data.List             ( lookup, map, (++) )
import Data.Int              ( Int )
import Data.Word             ( Word8, Word16 )
import Data.Char             ( String )
import Data.Eq               ( Eq, (==) )
import Data.Ord              ( Ord, (<), (>) )
import Data.Bool             ( Bool(False, True), not, otherwise )
import Data.Bits             ( Bits, (.|.), setBit, testBit, shiftL )
import System.IO             ( IO )
import System.IO.Unsafe      ( unsafePerformIO )
import Text.Show             ( Show, show )
import Text.Read             ( Read )
import Text.Printf           ( printf )

#if __GLASGOW_HASKELL__ < 700
import Prelude               ( fromInteger, negate )
import Control.Monad         ( (>>), fail )
#endif

-- from base-unicode-symbols:
import Data.Function.Unicode ( (∘) )
import Data.Bool.Unicode     ( (∧) )
import Data.Eq.Unicode       ( (≢), (≡) )

-- from bytestring:
import qualified Data.ByteString          as B  ( ByteString, packCStringLen, drop, length )
import qualified Data.ByteString.Internal as BI ( createAndTrim, createAndTrim' )
import qualified Data.ByteString.Unsafe   as BU ( unsafeUseAsCStringLen )

-- from text:
import           Data.Text                ( Text )
import qualified Data.Text.Encoding as TE ( decodeUtf16LE )

-- from bindings-libusb:
import Bindings.Libusb

-- from usb:
import Utils ( bits, between, genToEnum, genFromEnum, mapPeekArray, ifM, decodeBCD )

--------------------------------------------------------------------------------

#ifdef HAS_EVENT_MANAGER
-- from base:
import Prelude                 ( undefined )
import Foreign.C.Types         ( CShort, CChar )
import Foreign.Marshal.Alloc   ( allocaBytes, free )
import Foreign.Marshal.Array   ( peekArray0, copyArray )
import Foreign.Storable        ( sizeOf, poke )
import Foreign.Ptr             ( nullFunPtr, freeHaskellFunPtr )
import Control.Monad           ( forM_ )
import Data.IORef              ( newIORef, atomicModifyIORef, readIORef )
import Data.Function           ( id )
import Data.List               ( foldl' )
import Data.Tuple              ( curry )
import System.Posix.Types      ( Fd(Fd) )
import Control.Exception       ( uninterruptibleMask_ )
import Control.Concurrent      ( forkIO, killThread )
import Control.Concurrent.MVar ( MVar, newEmptyMVar, takeMVar, putMVar )
import System.IO               ( hPutStrLn, stderr )

-- TODO: In ghc-7.1 this will be renamed to GHC.Event:
import System.Event ( EventManager, new, loop, shutdown
                    , FdKey, registerFd, unregisterFd
                    , registerTimeout, unregisterTimeout
                    )

import qualified Foreign.Concurrent as FC ( newForeignPtr )

-- from containers:
import Data.IntMap ( IntMap, empty, insert, (!) )

-- from bytestring:
import qualified Data.ByteString.Internal as BI ( create )
import qualified Data.ByteString.Unsafe   as BU ( unsafeUseAsCString )

-- from usb:
import Utils          ( threaded )
import Timeval        ( withTimeval )
import qualified Poll ( toEvent )
#endif

--------------------------------------------------------------------------------

#if MIN_VERSION_base(4,3,0)
import Control.Exception ( mask, mask_ )
#else
import Control.Exception ( blocked, block, unblock )
import Data.Function     ( id )

mask ∷ ((IO α → IO α) → IO β) → IO β
mask io = do
  b ← blocked
  if b
     then io id
     else block $ io unblock

mask_ ∷ IO α → IO α
mask_ = block
#endif

#define COMMON_INSTANCES Show, Read, Eq, Data, Typeable

--------------------------------------------------------------------------------
-- * Initialization
--------------------------------------------------------------------------------

{-| Abstract type representing a USB session.

The concept of individual sessions allows your program to use multiple threads
that can independently use this library without interfering with eachother.

Sessions are created and initialized by 'newCtx' and are automatically closed
when they are garbage collected.

The only functions that receive a @Ctx@ are 'setDebug' and 'getDevices'.
-}
#ifdef HAS_EVENT_MANAGER
data Ctx = Ctx { getEventManager ∷ !(Maybe (EventManager, Maybe (IO ())))
               , getCtxFrgnPtr   ∷ !(ForeignPtr C'libusb_context)
               }
#else
newtype Ctx = Ctx { getCtxFrgnPtr ∷ ForeignPtr C'libusb_context }
#endif
    deriving Typeable

instance Eq Ctx where (==) = (==) `on` getCtxFrgnPtr

withCtxPtr ∷ Ctx → (Ptr C'libusb_context → IO α) → IO α
withCtxPtr = withForeignPtr ∘ getCtxFrgnPtr

init ∷ IO (Ptr C'libusb_context)
init = alloca $ \ctxPtrPtr → do
         handleUSBException $ c'libusb_init ctxPtrPtr
         peek ctxPtrPtr

newCtxNoEventManager ∷ (ForeignPtr  C'libusb_context → Ctx) → IO Ctx
newCtxNoEventManager ctx = mask_ $ do
                             ctxPtr ← init
                             ctx <$> newForeignPtr p'libusb_exit ctxPtr

#ifndef HAS_EVENT_MANAGER
-- | Create and initialize a new USB context.
--
-- This function may throw 'USBException's.
newCtx ∷ IO Ctx
newCtx = newCtxNoEventManager Ctx
#else
--------------------------------------------------------------------------------

{-| Create and initialize a new USB context.

This function may throw 'USBException's.

Note that the internal @libusb@ event handling can return errors. These errors
occur in the thread that is executing the event handling loop. 'newCtx' will
print these errors to 'stderr'. If you need to handle the errors yourself (for
example log them in an application specific way) please use 'newCtx''.
-}
newCtx ∷ IO Ctx
newCtx = newCtx' $ \e → hPutStrLn stderr $
  thisModule ++ ": libusb_handle_events_timeout returned error: " ++ show e

-- | Like 'newCtx' but enables you to specify the way errors should be handled
-- that occur while handling @libusb@ events.
newCtx' ∷ (USBException → IO ()) → IO Ctx
newCtx' handleError | not threaded = newCtxNoEventManager $ Ctx Nothing
                    | otherwise    = mask_ $ do
  ctxPtr ← init

  evtMgr ← new

  -- Maps libusb file descriptors (as Ints) to keys from the event manager:
  fdKeyMapRef ← newIORef (empty ∷ IntMap FdKey)

  let handleEvents ∷ IO ()
      handleEvents = do
        err ← withTimeval noTimeout $
                c'libusb_handle_events_timeout ctxPtr
        when (err ≢ c'LIBUSB_SUCCESS) $
             handleError $ convertUSBException err

      register ∷ CInt → CShort → IO ()
      register fd evt = do
        fdKey ← registerFd evtMgr (\_ _ → handleEvents) (Fd fd) (Poll.toEvent evt)

        atomicModifyIORef fdKeyMapRef $ \fdKeyMap →
          (insert (fromIntegral fd) fdKey fdKeyMap, ())

      unregister ∷ CInt → IO ()
      unregister fd = do
        fdKeyMap ← readIORef fdKeyMapRef
        let fdKey = fdKeyMap ! fromIntegral fd
        unregisterFd evtMgr fdKey

  -- Register initial libusb file descriptors with the event manager:
  pollFdPtrLst ← c'libusb_get_pollfds ctxPtr
  pollFdPtrs ← peekArray0 nullPtr pollFdPtrLst
  forM_ pollFdPtrs $ \pollFdPtr → do
    C'libusb_pollfd fd evt ← peek pollFdPtr
    register fd evt
  free pollFdPtrLst

  -- Be notified when libusb file descriptors are added or removed:
  aFP ← mkPollFdAddedCb   $ \fd evt _ → register   fd evt
  rFP ← mkPollFdRemovedCb $ \fd     _ → unregister fd
  c'libusb_set_pollfd_notifiers ctxPtr aFP rFP nullPtr

  -- Check if we have to do our own timeout handling:
  r ← c'libusb_pollfds_handle_timeouts ctxPtr
  let mbHandleEvents | r ≡ 0     = Just handleEvents
                     | otherwise = Nothing

  -- Start a thread that runs the event handling loop:
  tid ← forkIO $ loop evtMgr

  fmap (Ctx (Just (evtMgr, mbHandleEvents))) $ FC.newForeignPtr ctxPtr $ do
    -- Stop the event handling loop by killing its thread:
    killThread tid

    -- Remove notifiers after which we can safely free the FunPtrs:
    c'libusb_set_pollfd_notifiers ctxPtr nullFunPtr nullFunPtr nullPtr
    freeHaskellFunPtr aFP
    freeHaskellFunPtr rFP

    -- Finally deinitialize libusb:
    c'libusb_exit ctxPtr

foreign import ccall "wrapper" mkPollFdAddedCb ∷ (CInt → CShort → Ptr () → IO ())
                                               → IO C'libusb_pollfd_added_cb

foreign import ccall "wrapper" mkPollFdRemovedCb ∷ (CInt → Ptr () → IO ())
                                                 → IO C'libusb_pollfd_removed_cb

#endif
--------------------------------------------------------------------------------

{-| Set message verbosity.

The default level is 'PrintNothing'. This means no messages are ever
printed. If you choose to increase the message verbosity level you must ensure
that your application does not close the @stdout@/@stderr@ file descriptors.

You are advised to set the debug level to 'PrintWarnings'. Libusb is
conservative with its message logging. Most of the time it will only log
messages that explain error conditions and other oddities. This will help you
debug your software.

The LIBUSB_DEBUG environment variable overrules the debug level set by this
function. The message verbosity is fixed to the value in the environment
variable if it is defined.

If @libusb@ was compiled without any message logging, this function does nothing:
you'll never get any messages.

If @libusb@ was compiled with verbose debug message logging, this function does
nothing: you'll always get messages from all levels.
-}
setDebug ∷ Ctx → Verbosity → IO ()
setDebug ctx verbosity = withCtxPtr ctx $ \ctxPtr →
                           c'libusb_set_debug ctxPtr $ genFromEnum verbosity

-- | Message verbosity
data Verbosity =
          PrintNothing  -- ^ No messages are ever printed by the library
        | PrintErrors   -- ^ Error messages are printed to stderr
        | PrintWarnings -- ^ Warning and error messages are printed to stderr
        | PrintInfo     -- ^ Informational messages are printed to stdout,
                        --   warning and error messages are printed to stderr
          deriving (Enum, Ord, COMMON_INSTANCES)

--------------------------------------------------------------------------------
-- * Enumeration
--------------------------------------------------------------------------------

{-| Abstract type representing a USB device detected on the system.

You can only obtain a USB device from the 'getDevices' function.

Certain operations can be performed on a device, but in order to do any I/O you
will have to first obtain a 'DeviceHandle' using 'openDevice'. Alternatively you
can use the @usb-safe@ package which provides type-safe device handling. See:

<http://hackage.haskell.org/package/usb-safe>

Just because you have a reference to a device does not mean it is necessarily
usable. The device may have been unplugged, you may not have permission to
operate such device or another process or driver may be using the device.

To get additional information about a device you can retrieve its descriptor
using 'deviceDesc'.
-}
data Device = Device
    { getCtx ∷ !Ctx -- ^ This reference to the 'Ctx' is needed so that it won't
                    --   get garbage collected. The finalizer "p'libusb_exit" is
                    --   run only when all references to 'Devices' are gone.

    , getDevFrgnPtr ∷ !(ForeignPtr C'libusb_device)

    , deviceDesc ∷ !DeviceDesc -- ^ Get the descriptor of the device.
    } deriving Typeable

-- | Equality on devices is defined by comparing their descriptors:
-- @(==) = (==) \`on\` `deviceDesc`@
instance Eq Device where
    (==) = (==) `on` deviceDesc

-- | Devices are shown in the same way as the popular @lsusb@ program:
--
-- @Bus \<busNumber\> Device \<address\>: ID \<vid\>:\<pid\>@
instance Show Device where
    show d = printf "Bus %03d Device %03d: ID %04x:%04x" (busNumber d)
                                                         (deviceAddress d)
                                                         (deviceVendorId desc)
                                                         (deviceProductId desc)
        where
          desc = deviceDesc d

withDevicePtr ∷ Device → (Ptr C'libusb_device → IO α) → IO α
withDevicePtr = withForeignPtr ∘ getDevFrgnPtr

{-| Returns a list of USB devices currently attached to the system.

This is your entry point into finding a USB device.

Exceptions:

 * 'NoMemException' on a memory allocation failure.

-}

{-
Visual description of the 'devPtrArrayPtr':

                              D
                              ^           D
                          D   │           ^
                          ^   │           │
                          │   │           │
devPtrArrayPtr:         ┏━┷━┳━┷━┳━━━┳━━━┳━┷━┓
                 P ───> ┃ P ┃ P ┃ P ┃ P ┃ P ┃
                        ┗━━━┻━━━┻━┯━┻━┯━┻━━━┛
                                  │   │
P = pointer                       v   │
D = device structure              D   │
                                      v
                                      D
-}
getDevices ∷ Ctx → IO [Device]
getDevices ctx =
    alloca $ \devPtrArrayPtr → mask $ \restore → do
      numDevs ← checkUSBException $ withCtxPtr ctx $
                  flip c'libusb_get_device_list devPtrArrayPtr
      devPtrArray ← peek devPtrArrayPtr
      let freeDevPtrArray = c'libusb_free_device_list devPtrArray 0
      devs ← restore (mapPeekArray mkDev numDevs devPtrArray)
               `onException` freeDevPtrArray
      freeDevPtrArray
      return devs
    where
      mkDev ∷ Ptr C'libusb_device → IO Device
      mkDev devPtr = liftA2 (Device ctx)
                            (newForeignPtr p'libusb_unref_device devPtr)
                            (getDeviceDesc devPtr)

-- Both of the following numbers are static variables in the libusb device
-- structure. It's therefore safe to use unsafePerformIO:

-- | The number of the bus that a device is connected to.
busNumber ∷ Device → Word8
busNumber dev = unsafePerformIO $ withDevicePtr dev c'libusb_get_bus_number

-- | The address of the device on the bus it is connected to.
deviceAddress ∷ Device → Word8
deviceAddress dev = unsafePerformIO $ withDevicePtr dev c'libusb_get_device_address

--------------------------------------------------------------------------------
-- * Device handling
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- ** Opening & closing devices
--------------------------------------------------------------------------------

{-| Abstract type representing a handle of a USB device.

You can acquire a handle from 'openDevice'.

A device handle is used to perform I/O and other operations. When finished with
a device handle you should close it by applying 'closeDevice' to it.
-}
data DeviceHandle = DeviceHandle
    { getDevice ∷ !Device -- This reference is needed for keeping the 'Device'
                          -- and therefor the 'Ctx' alive.
                          -- ^ Retrieve the 'Device' from the 'DeviceHandle'.
    , getDevHndlPtr ∷ !(Ptr C'libusb_device_handle)
                          -- ^ Retrieve the pointer to the @libusb@ device handle.
    } deriving Typeable

instance Eq DeviceHandle where
    (==) = (==) `on` getDevHndlPtr

instance Show DeviceHandle where
    show devHndl = "{USB device handle to: " ++ show (getDevice devHndl) ++ "}"

{-| Open a device and obtain a device handle.

A handle allows you to perform I/O on the device in question.

This is a non-blocking function; no requests are sent over the bus.

It is advisable to use 'withDeviceHandle' because it automatically closes the
device when the computation terminates.

Exceptions:

 * 'NoMemException' if there is a memory allocation failure.

 * 'AccessException' if the user has insufficient permissions.

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}
openDevice ∷ Device → IO DeviceHandle
openDevice dev = withDevicePtr dev $ \devPtr →
                   alloca $ \devHndlPtrPtr → do
                     handleUSBException $ c'libusb_open devPtr devHndlPtrPtr
                     DeviceHandle dev <$> peek devHndlPtrPtr

{-| Close a device handle.

Should be called on all open handles before your application exits.

This is a non-blocking function; no requests are sent over the bus.
-}
closeDevice ∷ DeviceHandle → IO ()
closeDevice = c'libusb_close ∘ getDevHndlPtr

{-| @withDeviceHandle dev act@ opens the 'Device' @dev@ and passes
the resulting handle to the computation @act@. The handle will be closed on exit
from @withDeviceHandle@ whether by normal termination or by raising an
exception.
-}
withDeviceHandle ∷ Device → (DeviceHandle → IO α) → IO α
withDeviceHandle dev = bracket (openDevice dev) closeDevice

--------------------------------------------------------------------------------
-- ** Getting & setting the configuration
--------------------------------------------------------------------------------

-- | Identifier for configurations.
--
-- Can be retrieved by 'getConfig' or by 'configValue'.
type ConfigValue = Word8

{-| Determine the value of the currently active configuration.

You could formulate your own control request to obtain this information, but
this function has the advantage that it may be able to retrieve the information
from operating system caches (no I/O involved).

If the OS does not cache this information, then this function will block while
a control transfer is submitted to retrieve the information.

This function returns 'Nothing' if the device is in unconfigured state.

Exceptions:

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}
getConfig ∷ DeviceHandle → IO (Maybe ConfigValue)
getConfig devHndl =
    alloca $ \configPtr → do
      handleUSBException $ c'libusb_get_configuration (getDevHndlPtr devHndl)
                                                      configPtr
      unmarshal <$> peek configPtr
        where
          unmarshal 0 = Nothing
          unmarshal n = Just $ fromIntegral n

{-| Set the active configuration for a device.

The operating system may or may not have already set an active configuration on
the device. It is up to your application to ensure the correct configuration is
selected before you attempt to claim interfaces and perform other operations.

If you call this function on a device already configured with the selected
configuration, then this function will act as a lightweight device reset: it
will issue a SET_CONFIGURATION request using the current configuration, causing
most USB-related device state to be reset (altsetting reset to zero, endpoint
halts cleared, toggles reset).

You cannot change/reset configuration if your application has claimed interfaces
- you should free them with 'releaseInterface' first. You cannot change/reset
configuration if other applications or drivers have claimed interfaces.

A configuration value of 'Nothing' will put the device in an unconfigured
state. The USB specification states that a configuration value of 0 does this,
however buggy devices exist which actually have a configuration 0.

You should always use this function rather than formulating your own
SET_CONFIGURATION control request. This is because the underlying operating
system needs to know when such changes happen.

This is a blocking function.

Exceptions:

 * 'NotFoundException' if the requested configuration does not exist.

 * 'BusyException' if interfaces are currently claimed.

 * 'NoDeviceException' if the device has been disconnected

 * Another 'USBException'.
-}
setConfig ∷ DeviceHandle → Maybe ConfigValue → IO ()
setConfig devHndl = handleUSBException
                  ∘ c'libusb_set_configuration (getDevHndlPtr devHndl)
                  ∘ marshal
                      where marshal = maybe (-1) fromIntegral

--------------------------------------------------------------------------------
-- ** Claiming & releasing interfaces
--------------------------------------------------------------------------------

{-| Identifier for interfaces.

Can be retrieved by 'interfaceNumber'.
-}
type InterfaceNumber = Word8

{-| Claim an interface on a given device handle.

You must claim the interface you wish to use before you can perform I/O on any
of its endpoints.

It is legal to attempt to claim an already-claimed interface, in which case this
function just returns without doing anything.

Claiming of interfaces is a purely logical operation; it does not cause any
requests to be sent over the bus. Interface claiming is used to instruct the
underlying operating system that your application wishes to take ownership of
the interface.

This is a non-blocking function.

Exceptions:

 * 'NotFoundException' if the requested interface does not exist.

 * 'BusyException' if the interface is already claimed.

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}

claimInterface ∷ DeviceHandle → InterfaceNumber → IO ()
claimInterface devHndl ifNum =
    handleUSBException $ c'libusb_claim_interface (getDevHndlPtr devHndl)
                                                  (fromIntegral ifNum)

{-| Release an interface previously claimed with 'claimInterface'.

You should release all claimed interfaces before closing a device handle.

This is a blocking function. A SET_INTERFACE control request will be sent to the
device, resetting interface state to the first alternate setting.

Exceptions:

 * 'NotFoundException' if the interface was not claimed.

 * 'NoDeviceException' if the device has been disconnected

 * Another 'USBException'.
-}
releaseInterface ∷ DeviceHandle → InterfaceNumber → IO ()
releaseInterface devHndl ifNum =
    handleUSBException $ c'libusb_release_interface (getDevHndlPtr devHndl)
                                                    (fromIntegral ifNum)

{-| @withClaimedInterface@ claims the interface on the given device handle then
executes the given computation. On exit from @withClaimedInterface@, the
interface is released whether by normal termination or by raising an exception.
-}
withClaimedInterface ∷ DeviceHandle → InterfaceNumber → IO α → IO α
withClaimedInterface devHndl ifNum = bracket_ (claimInterface   devHndl ifNum)
                                              (releaseInterface devHndl ifNum)

--------------------------------------------------------------------------------
-- ** Setting interface alternate settings
--------------------------------------------------------------------------------

-- | Identifier for interface alternate settings.
--
-- Can be retrieved by 'interfaceAltSetting'.
type InterfaceAltSetting = Word8

{-| Activate an alternate setting for an interface.

The interface must have been previously claimed with 'claimInterface' or
'withInterfaceHandle'.

You should always use this function rather than formulating your own
SET_INTERFACE control request. This is because the underlying operating system
needs to know when such changes happen.

This is a blocking function.

Exceptions:

 * 'NotFoundException' if the interface was not claimed or the requested
   alternate setting does not exist.

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}
setInterfaceAltSetting ∷ DeviceHandle
                       → InterfaceNumber
                       → InterfaceAltSetting
                       → IO ()
setInterfaceAltSetting devHndl ifNum alternateSetting =
    handleUSBException $
      c'libusb_set_interface_alt_setting (getDevHndlPtr devHndl)
                                         (fromIntegral ifNum)
                                         (fromIntegral alternateSetting)

--------------------------------------------------------------------------------
-- ** Clearing & Resetting devices
--------------------------------------------------------------------------------

{-| Clear the halt/stall condition for an endpoint.

Endpoints with halt status are unable to receive or transmit data until the halt
condition is stalled.

You should cancel all pending transfers before attempting to clear the halt
condition.

This is a blocking function.

Exceptions:

 * 'NotFoundException' if the endpoint does not exist.

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}
clearHalt ∷ DeviceHandle → EndpointAddress → IO ()
clearHalt devHndl = handleUSBException
                  ∘ c'libusb_clear_halt (getDevHndlPtr devHndl)
                  ∘ marshalEndpointAddress

{-| Perform a USB port reset to reinitialize a device.

The system will attempt to restore the previous configuration and alternate
settings after the reset has completed.

If the reset fails, the descriptors change, or the previous state cannot be
restored, the device will appear to be disconnected and reconnected. This means
that the device handle is no longer valid (you should close it) and rediscover
the device. A 'NotFoundException' is raised to indicate that this is the
case.

This is a blocking function which usually incurs a noticeable delay.

Exceptions:

 * 'NotFoundException' if re-enumeration is required, or if the
   device has been disconnected.

 * Another 'USBException'.
-}
resetDevice ∷ DeviceHandle → IO ()
resetDevice = handleUSBException ∘ c'libusb_reset_device ∘ getDevHndlPtr

--------------------------------------------------------------------------------
-- ** USB kernel drivers
--------------------------------------------------------------------------------

{-| Determine if a kernel driver is active on an interface.

If a kernel driver is active, you cannot claim the interface, and libusb will be
unable to perform I/O.

Exceptions:

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}
kernelDriverActive ∷ DeviceHandle → InterfaceNumber → IO Bool
kernelDriverActive devHndl ifNum = do
  r ← c'libusb_kernel_driver_active (getDevHndlPtr devHndl)
                                    (fromIntegral ifNum)
  case r of
    0 → return False
    1 → return True
    _ → throwIO $ convertUSBException r

{-| Detach a kernel driver from an interface.

If successful, you will then be able to claim the interface and perform I/O.

Exceptions:

 * 'NotFoundException' if no kernel driver was active.

 * 'InvalidParamException' if the interface does not exist.

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}
detachKernelDriver ∷ DeviceHandle → InterfaceNumber → IO ()
detachKernelDriver devHndl ifNum =
    handleUSBException $ c'libusb_detach_kernel_driver (getDevHndlPtr devHndl)
                                                       (fromIntegral ifNum)

{-| Re-attach an interface's kernel driver, which was previously
detached using 'detachKernelDriver'.

Exceptions:

 * 'NotFoundException' if no kernel driver was active.

 * 'InvalidParamException' if the interface does not exist.

 * 'NoDeviceException' if the device has been disconnected.

 * 'BusyException' if the driver cannot be attached because the interface
   is claimed by a program or driver.

 * Another 'USBException'.
-}
attachKernelDriver ∷ DeviceHandle → InterfaceNumber → IO ()
attachKernelDriver devHndl ifNum =
    handleUSBException $ c'libusb_attach_kernel_driver (getDevHndlPtr devHndl)
                                                       (fromIntegral ifNum)

{-| If a kernel driver is active on the specified interface the driver is
detached and the given action is executed. If the action terminates, whether by
normal termination or by raising an exception, the kernel driver is attached
again. If a kernel driver is not active on the specified interface the action is
just executed.

Exceptions:

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}
withDetachedKernelDriver ∷ DeviceHandle → InterfaceNumber → IO α → IO α
withDetachedKernelDriver devHndl ifNum action =
    ifM (kernelDriverActive devHndl ifNum)
        (bracket_ (detachKernelDriver devHndl ifNum)
                  (attachKernelDriver devHndl ifNum)
                  action)
        action

--------------------------------------------------------------------------------
-- * Descriptors
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- ** Device descriptor
--------------------------------------------------------------------------------

{-| A structure representing the standard USB device descriptor.

This descriptor is documented in section 9.6.1 of the USB 2.0 specification.

This structure can be retrieved by 'deviceDesc'.
-}
data DeviceDesc = DeviceDesc
    { -- | USB specification release number.
      deviceUSBSpecReleaseNumber ∷ !ReleaseNumber

      -- | USB-IF class code for the device.
    , deviceClass ∷ !Word8

      -- | USB-IF subclass code for the device, qualified by the 'deviceClass'
      -- value.
    , deviceSubClass ∷ !Word8

      -- | USB-IF protocol code for the device, qualified by the 'deviceClass'
      -- and 'deviceSubClass' values.
    , deviceProtocol ∷ !Word8

      -- | Maximum packet size for endpoint 0.
    , deviceMaxPacketSize0 ∷ !Word8

      -- | USB-IF vendor ID.
    , deviceVendorId ∷ !VendorId

      -- | USB-IF product ID.
    , deviceProductId ∷ !ProductId

      -- | Device release number.
    , deviceReleaseNumber ∷ !ReleaseNumber

      -- | Optional index of string descriptor describing manufacturer.
    , deviceManufacturerStrIx ∷ !(Maybe StrIx)

      -- | Optional index of string descriptor describing product.
    , deviceProductStrIx ∷ !(Maybe StrIx)

      -- | Optional index of string descriptor containing device serial number.
    , deviceSerialNumberStrIx ∷ !(Maybe StrIx)

      -- | Number of possible configurations.
    , deviceNumConfigs ∷ !Word8

      -- | List of configurations supported by the device.
    , deviceConfigs ∷ ![ConfigDesc]
    } deriving (COMMON_INSTANCES)

type ReleaseNumber = (Int, Int, Int, Int)

type VendorId  = Word16
type ProductId = Word16

--------------------------------------------------------------------------------
-- ** Configuration descriptor
--------------------------------------------------------------------------------

{-| A structure representing the standard USB configuration descriptor.

This descriptor is documented in section 9.6.3 of the USB 2.0 specification.

This structure can be retrieved by 'deviceConfigs'.
-}
data ConfigDesc = ConfigDesc
    { -- | Identifier value for the configuration.
      configValue ∷ !ConfigValue

      -- | Optional index of string descriptor describing the configuration.
    , configStrIx ∷ !(Maybe StrIx)

      -- | Configuration characteristics.
    , configAttribs ∷ !ConfigAttribs

      -- | Maximum power consumption of the USB device from the bus in the
      -- configuration when the device is fully operational.  Expressed in 2 mA
      -- units (i.e., 50 = 100 mA).
    , configMaxPower ∷ !Word8

      -- | Number of interfaces supported by the configuration.
    , configNumInterfaces ∷ !Word8

      -- | List of interfaces supported by the configuration.  Note that the
      -- length of this list should equal 'configNumInterfaces'.
    , configInterfaces ∷ ![Interface]

      -- | Extra descriptors. If @libusb@ encounters unknown configuration
      -- descriptors, it will store them here, should you wish to parse them.
    , configExtra ∷ !B.ByteString

    } deriving (COMMON_INSTANCES)

-- | An interface is represented as a list of alternate interface settings.
type Interface = [InterfaceDesc]

--------------------------------------------------------------------------------
-- *** Configuration attributes
--------------------------------------------------------------------------------

-- | The USB 2.0 specification specifies that the configuration attributes only
-- describe the device status.
type ConfigAttribs = DeviceStatus

data DeviceStatus = DeviceStatus
    { remoteWakeup ∷ !Bool -- ^ The Remote Wakeup field indicates whether the
                           --   device is currently enabled to request remote
                           --   wakeup. The default mode for devices that
                           --   support remote wakeup is disabled.
    , selfPowered  ∷ !Bool -- ^ The Self Powered field indicates whether the
                           --   device is currently self-powered
    } deriving (COMMON_INSTANCES)

--------------------------------------------------------------------------------
-- ** Interface descriptor
--------------------------------------------------------------------------------

{-| A structure representing the standard USB interface descriptor.

This descriptor is documented in section 9.6.5 of the USB 2.0 specification.

This structure can be retrieved using 'configInterfaces'.
-}
data InterfaceDesc = InterfaceDesc
    { -- | Number of the interface.
      interfaceNumber ∷ !InterfaceNumber

      -- | Value used to select the alternate setting for the interface.
    , interfaceAltSetting ∷ !InterfaceAltSetting

      -- | USB-IF class code for the interface.
    , interfaceClass ∷ !Word8

      -- | USB-IF subclass code for the interface, qualified by the
      -- 'interfaceClass' value.
    , interfaceSubClass ∷ !Word8

      -- | USB-IF protocol code for the interface, qualified by the
      -- 'interfaceClass' and 'interfaceSubClass' values.
    , interfaceProtocol ∷ !Word8

      -- | Optional index of string descriptor describing the interface.
    , interfaceStrIx ∷ !(Maybe StrIx)

      -- | List of endpoints supported by the interface.
    , interfaceEndpoints ∷ ![EndpointDesc]

      -- | Extra descriptors. If @libusb@ encounters unknown interface
      -- descriptors, it will store them here, should you wish to parse them.
    , interfaceExtra ∷ !B.ByteString
    } deriving (COMMON_INSTANCES)

--------------------------------------------------------------------------------
-- ** Endpoint descriptor
--------------------------------------------------------------------------------

{-| A structure representing the standard USB endpoint descriptor.

This descriptor is documented in section 9.6.3 of the USB 2.0 specification.

This structure can be retrieved by using 'interfaceEndpoints'.
-}
data EndpointDesc = EndpointDesc
    { -- | The address of the endpoint described by the descriptor.
      endpointAddress ∷ !EndpointAddress

    -- | Attributes which apply to the endpoint when it is configured using the
    -- 'configValue'.
    , endpointAttribs ∷ !EndpointAttribs

    -- | Maximum packet size the endpoint is capable of sending/receiving.
    , endpointMaxPacketSize ∷ !MaxPacketSize

    -- | Interval for polling endpoint for data transfers. Expressed in frames
    -- or microframes depending on the device operating speed (i.e., either 1
    -- millisecond or 125 &#956;s units).
    , endpointInterval ∷ !Word8

    -- | /For audio devices only:/ the rate at which synchronization feedback
    -- is provided.
    , endpointRefresh ∷ !Word8

    -- | /For audio devices only:/ the address of the synch endpoint.
    , endpointSynchAddress ∷ !Word8

    -- | Extra descriptors. If @libusb@ encounters unknown endpoint descriptors,
    -- it will store them here, should you wish to parse them.
    , endpointExtra ∷ !B.ByteString
    } deriving (COMMON_INSTANCES)

--------------------------------------------------------------------------------
-- *** Endpoint address
--------------------------------------------------------------------------------

-- | The address of an endpoint.
data EndpointAddress = EndpointAddress
    { endpointNumber    ∷ !Int -- ^ Must be >= 0 and <= 15
    , transferDirection ∷ !TransferDirection
    } deriving (COMMON_INSTANCES)

-- | The direction of data transfer relative to the host.
data TransferDirection = Out -- ^ Out transfer direction (host -> device) used
                             --   for writing.
                       | In  -- ^ In transfer direction (device -> host) used
                             --   for reading.
                 deriving (COMMON_INSTANCES)

--------------------------------------------------------------------------------
-- *** Endpoint attributes
--------------------------------------------------------------------------------

-- | The USB 2.0 specification specifies that the endpoint attributes only
-- describe the endpoint transfer type.
type EndpointAttribs = TransferType

-- | Describes what types of transfers are allowed on the endpoint.
data TransferType =
          -- | Control transfers are typically used for command and status
          -- operations.
          Control

          -- | Isochronous transfers occur continuously and periodically.
        | Isochronous !Synchronization !Usage

          -- | Bulk transfers can be used for large bursty data.
        | Bulk

          -- | Interrupt transfers are typically non-periodic, small device
          -- \"initiated\" communication requiring bounded latency.
        | Interrupt
          deriving (COMMON_INSTANCES)

-- | See section 5.12.4.1 of the USB 2.0 specification.
data Synchronization =
          NoSynchronization
        | Asynchronous -- ^ Unsynchronized,
                       --   although sinks provide data rate feedback.
        | Adaptive     -- ^ Synchronized using feedback or feedforward
                       --   data rate information
        | Synchronous  -- ^ Synchronized to the USB’s SOF (/Start Of Frame/)
          deriving (Enum, COMMON_INSTANCES)

-- | See section 5.12.4.2 of the USB 2.0 specification.
data Usage = Data
           | Feedback
           | Implicit
             deriving (Enum, COMMON_INSTANCES)

--------------------------------------------------------------------------------
-- *** Endpoint max packet size
--------------------------------------------------------------------------------

data MaxPacketSize = MaxPacketSize
    { maxPacketSize            ∷ !Size
    , transactionOpportunities ∷ !TransactionOpportunities
    } deriving (COMMON_INSTANCES)

-- | Number of additional transactions.
data TransactionOpportunities = Zero | One | Two
         deriving (Enum, Ord, COMMON_INSTANCES)

{-| Calculate the maximum packet size which a specific endpoint is capable of
sending or receiving in the duration of 1 microframe.

If acting on an 'Isochronous' or 'Interrupt' endpoint, this function will
multiply the 'maxPacketSize' by the 'transactionOpportunities'. If acting on
another type of endpoint only the 'maxPacketSize' is returned.

This function is mainly useful for setting up /isochronous/ transfers.
-}
maxIsoPacketSize ∷ EndpointDesc → Size
maxIsoPacketSize epDesc | isochronousOrInterrupt = mps * fromEnum to
                        | otherwise              = mps
    where
      MaxPacketSize mps to = endpointMaxPacketSize epDesc

      isochronousOrInterrupt = case endpointAttribs epDesc of
                                 Isochronous _ _ → True
                                 Interrupt       → True
                                 _               → False

--------------------------------------------------------------------------------
-- ** Retrieving and converting descriptors
--------------------------------------------------------------------------------

getDeviceDesc ∷ Ptr C'libusb_device → IO DeviceDesc
getDeviceDesc devPtr = alloca $ \devDescPtr → do
    handleUSBException $ c'libusb_get_device_descriptor devPtr devDescPtr
    peek devDescPtr >>= convertDeviceDesc devPtr

convertDeviceDesc ∷ Ptr C'libusb_device
                  → C'libusb_device_descriptor
                  → IO DeviceDesc
convertDeviceDesc devPtr d = do
    let numConfigs = c'libusb_device_descriptor'bNumConfigurations d

    configs ← forM [0..numConfigs-1] $ getConfigDesc devPtr

    return DeviceDesc
      { deviceUSBSpecReleaseNumber = unmarshalReleaseNumber $
                                     c'libusb_device_descriptor'bcdUSB          d
      , deviceClass                = c'libusb_device_descriptor'bDeviceClass    d
      , deviceSubClass             = c'libusb_device_descriptor'bDeviceSubClass d
      , deviceProtocol             = c'libusb_device_descriptor'bDeviceProtocol d
      , deviceMaxPacketSize0       = c'libusb_device_descriptor'bMaxPacketSize0 d
      , deviceVendorId             = c'libusb_device_descriptor'idVendor        d
      , deviceProductId            = c'libusb_device_descriptor'idProduct       d
      , deviceReleaseNumber        = unmarshalReleaseNumber $
                                     c'libusb_device_descriptor'bcdDevice       d
      , deviceManufacturerStrIx    = unmarshalStrIx $
                                     c'libusb_device_descriptor'iManufacturer   d
      , deviceProductStrIx         = unmarshalStrIx $
                                     c'libusb_device_descriptor'iProduct        d
      , deviceSerialNumberStrIx    = unmarshalStrIx $
                                     c'libusb_device_descriptor'iSerialNumber   d
      , deviceNumConfigs           = numConfigs
      , deviceConfigs              = configs
      }

-- | Unmarshal a a 16bit word as a release number. The 16bit word should be
-- encoded as a Binary Coded Decimal using 4 bits for each of the 4
-- decimals. Also see:
--
-- <http://en.wikipedia.org/wiki/Binary-coded_decimal>
unmarshalReleaseNumber ∷ Word16 → ReleaseNumber
unmarshalReleaseNumber abcd = (a, b, c, d)
    where
      [a, b, c, d] = map fromIntegral $ decodeBCD 4 abcd

-- | Unmarshal an 8bit word to a string descriptor index. 0 denotes that a
-- string descriptor is not available and unmarshals to 'Nothing'.
unmarshalStrIx ∷ Word8 → Maybe StrIx
unmarshalStrIx 0     = Nothing
unmarshalStrIx strIx = Just strIx

getConfigDesc ∷ Ptr C'libusb_device → Word8 → IO ConfigDesc
getConfigDesc devPtr ix = bracket getConfigDescPtr
                                  c'libusb_free_config_descriptor
                                  ((convertConfigDesc =<<) ∘ peek)
    where
      getConfigDescPtr = alloca $ \configDescPtrPtr → do
                           handleUSBException $ c'libusb_get_config_descriptor
                                                  devPtr
                                                  ix
                                                  configDescPtrPtr
                           peek configDescPtrPtr

convertConfigDesc ∷ C'libusb_config_descriptor → IO ConfigDesc
convertConfigDesc c = do
    let numInterfaces = c'libusb_config_descriptor'bNumInterfaces c

    interfaces ← mapPeekArray convertInterface
                              (fromIntegral numInterfaces)
                              (c'libusb_config_descriptor'interface c)

    extra ← getExtra (c'libusb_config_descriptor'extra c)
                     (c'libusb_config_descriptor'extra_length c)

    return ConfigDesc
      { configValue         = c'libusb_config_descriptor'bConfigurationValue c
      , configStrIx         = unmarshalStrIx $
                              c'libusb_config_descriptor'iConfiguration      c
      , configAttribs       = unmarshalConfigAttribs $
                              c'libusb_config_descriptor'bmAttributes        c
      , configMaxPower      = c'libusb_config_descriptor'MaxPower            c
      , configNumInterfaces = numInterfaces
      , configInterfaces    = interfaces
      , configExtra         = extra
      }

unmarshalConfigAttribs ∷ Word8 → ConfigAttribs
unmarshalConfigAttribs a = DeviceStatus { remoteWakeup = testBit a 5
                                        , selfPowered  = testBit a 6
                                        }

getExtra ∷ Ptr CUChar → CInt → IO B.ByteString
getExtra extra extraLength = B.packCStringLen ( castPtr extra
                                              , fromIntegral extraLength
                                              )

convertInterface ∷ C'libusb_interface → IO [InterfaceDesc]
convertInterface i =
    mapPeekArray convertInterfaceDesc
                 (fromIntegral $ c'libusb_interface'num_altsetting i)
                 (c'libusb_interface'altsetting i)

convertInterfaceDesc ∷ C'libusb_interface_descriptor → IO InterfaceDesc
convertInterfaceDesc i = do
  let numEndpoints = c'libusb_interface_descriptor'bNumEndpoints i

  endpoints ← mapPeekArray convertEndpointDesc
                           (fromIntegral numEndpoints)
                           (c'libusb_interface_descriptor'endpoint i)

  extra ← getExtra (c'libusb_interface_descriptor'extra i)
                   (c'libusb_interface_descriptor'extra_length i)

  return InterfaceDesc
    { interfaceNumber     = c'libusb_interface_descriptor'bInterfaceNumber   i
    , interfaceAltSetting = c'libusb_interface_descriptor'bAlternateSetting  i
    , interfaceClass      = c'libusb_interface_descriptor'bInterfaceClass    i
    , interfaceSubClass   = c'libusb_interface_descriptor'bInterfaceSubClass i
    , interfaceStrIx      = unmarshalStrIx $
                            c'libusb_interface_descriptor'iInterface         i
    , interfaceProtocol   = c'libusb_interface_descriptor'bInterfaceProtocol i
    , interfaceEndpoints  = endpoints
    , interfaceExtra      = extra
    }

convertEndpointDesc ∷ C'libusb_endpoint_descriptor → IO EndpointDesc
convertEndpointDesc e = do
  extra ← getExtra (c'libusb_endpoint_descriptor'extra e)
                   (c'libusb_endpoint_descriptor'extra_length e)

  return EndpointDesc
    { endpointAddress       = unmarshalEndpointAddress $
                              c'libusb_endpoint_descriptor'bEndpointAddress e
    , endpointAttribs       = unmarshalEndpointAttribs $
                              c'libusb_endpoint_descriptor'bmAttributes     e
    , endpointMaxPacketSize = unmarshalMaxPacketSize $
                              c'libusb_endpoint_descriptor'wMaxPacketSize   e
    , endpointInterval      = c'libusb_endpoint_descriptor'bInterval        e
    , endpointRefresh       = c'libusb_endpoint_descriptor'bRefresh         e
    , endpointSynchAddress  = c'libusb_endpoint_descriptor'bSynchAddress    e
    , endpointExtra         = extra
    }

-- | Unmarshal an 8bit word as an endpoint address. This function is primarily
-- used when unmarshalling USB descriptors.
unmarshalEndpointAddress ∷ Word8 → EndpointAddress
unmarshalEndpointAddress a =
    EndpointAddress { endpointNumber    = fromIntegral $ bits 0 3 a
                    , transferDirection = if testBit a 7 then In else Out
                    }

-- | Marshal an endpoint address so that it can be used by the @libusb@ transfer
-- functions.
marshalEndpointAddress ∷ (Bits α, Num α) ⇒ EndpointAddress → α
marshalEndpointAddress (EndpointAddress num transDir) =
    assert (between num 0 15) $ let n = fromIntegral num
                                in case transDir of
                                     Out → n
                                     In  → setBit n 7

unmarshalEndpointAttribs ∷ Word8 → EndpointAttribs
unmarshalEndpointAttribs a =
    case bits 0 1 a of
      0 → Control
      1 → Isochronous (genToEnum $ bits 2 3 a)
                      (genToEnum $ bits 4 5 a)
      2 → Bulk
      3 → Interrupt
      _ → moduleError "unmarshalEndpointAttribs: this can't happen!"

unmarshalMaxPacketSize ∷ Word16 → MaxPacketSize
unmarshalMaxPacketSize m =
    MaxPacketSize
    { maxPacketSize            = fromIntegral $ bits 0  10 m
    , transactionOpportunities = genToEnum    $ bits 11 12 m
    }

--------------------------------------------------------------------------------
-- ** String descriptors
--------------------------------------------------------------------------------

-- | The size in number of bytes of the header of string descriptors.
strDescHeaderSize ∷ Size
strDescHeaderSize = 2

-- | Characters are encoded as UTF16LE so each character takes two bytes.
charSize ∷ Size
charSize = 2

{-| Retrieve a list of supported languages.

This function may throw 'USBException's.
-}
getLanguages ∷ DeviceHandle → IO [LangId]
getLanguages devHndl = allocaArray maxSize $ \dataPtr → do
  reportedSize ← write dataPtr

  let strSize = (reportedSize - strDescHeaderSize) `div` charSize
      strPtr = castPtr $ dataPtr `plusPtr` strDescHeaderSize

  map unmarshalLangId <$> peekArray strSize strPtr
      where
        maxSize = 255 -- Some devices choke on size > 255
        write = putStrDesc devHndl 0 0 maxSize

{-| @putStrDesc devHndl strIx langId maxSize dataPtr@ retrieves the
string descriptor @strIx@ in the language @langId@ from the @devHndl@
and writes at most @maxSize@ bytes from that string descriptor to the
location that @dataPtr@ points to. So ensure there is at least space
for @maxSize@ bytes there. Next, the header of the string descriptor
is checked for correctness. If it's incorrect an 'IOException' is
thrown. Finally, the size reported in the header is returned.
-}
putStrDesc ∷ DeviceHandle
           → StrIx
           → Word16
           → Size
           → Ptr CUChar
           → IO Size
putStrDesc devHndl strIx langId maxSize dataPtr = do
    actualSize ← checkUSBException $ c'libusb_get_string_descriptor
                                        (getDevHndlPtr devHndl)
                                        strIx
                                        langId
                                        dataPtr
                                        (fromIntegral maxSize)
    when (actualSize < strDescHeaderSize) $
         throwIO $ IOException "Incomplete header"

    reportedSize ← peek dataPtr

    when (reportedSize > fromIntegral actualSize) $
         throwIO $ IOException "Not enough space to hold data"

    descType ← peekElemOff dataPtr 1

    when (descType ≢ c'LIBUSB_DT_STRING) $
         throwIO $ IOException "Invalid header"

    return $ fromIntegral reportedSize

{-| The language ID consists of the primary language identifier and the
sublanguage identififier as described in:

<http://www.usb.org/developers/docs/USB_LANGIDs.pdf>

For a mapping between IDs and languages see the @usb-id-database@ package at:

<http://hackage.haskell.org/package/usb-id-database>

To see which 'LangId's are supported by a device see 'getLanguages'.
-}
type LangId = (PrimaryLangId, SubLangId)
type PrimaryLangId = Word16
type SubLangId     = Word16

unmarshalLangId ∷ Word16 → LangId
unmarshalLangId = bits 0 9 &&& bits 10 15

marshalLangId ∷ LangId → Word16
marshalLangId (p, s) = p .|. s `shiftL`10

-- | Type of indici of string descriptors.
--
-- Can be retrieved by all the *StrIx functions.
type StrIx = Word8

{-| Retrieve a string descriptor from a device.

This function may throw 'USBException's.
-}
getStrDesc ∷ DeviceHandle
           → StrIx
           → LangId
           → Int -- ^ Maximum number of characters in the requested string. An
                 --   'IOException' will be thrown when the requested string is
                 --   larger than this number.
           → IO Text
getStrDesc devHndl strIx langId nrOfChars = assert (strIx ≢ 0) $
    fmap decode $ BI.createAndTrim size $ write ∘ castPtr
        where
          write  = putStrDesc devHndl strIx (marshalLangId langId) size
          size   = strDescHeaderSize + nrOfChars * charSize
          decode = TE.decodeUtf16LE ∘ B.drop strDescHeaderSize

{-| Retrieve a string descriptor from a device using the first supported language.

This function may throw 'USBException's.
-}
getStrDescFirstLang ∷ DeviceHandle
                    → StrIx
                    → Int -- ^ Maximum number of characters in the requested
                          --   string. An 'IOException' will be thrown when the
                          --   requested string is larger than this number.
                    → IO Text
getStrDescFirstLang devHndl strIx nrOfChars =
    do langIds ← getLanguages devHndl
       case langIds of
         []         → throwIO $ IOException "Zero languages"
         langId : _ → getStrDesc devHndl strIx langId nrOfChars

--------------------------------------------------------------------------------
-- * I/O
--------------------------------------------------------------------------------

{-| Handy type synonym for read transfers.

A @ReadAction@ is a function which takes a 'Size' which defines how many bytes
to read and a 'Timeout'. The function returns an 'IO' action which, when
executed, performs the actual read and returns the 'B.ByteString' that was read
paired with a 'Status' flag which indicates whether the transfer
'Completed' or 'TimedOut'.
-}
type ReadAction = Size → Timeout → IO (B.ByteString, Status)

-- | Handy type synonym for read transfers that must exactly read the specified
-- number of bytes. An 'incompleteReadException' is thrown otherwise.
type ReadExactAction = Size → Timeout → IO B.ByteString

{-| Handy type synonym for write transfers.

A @WriteAction@ is a function which takes a 'B.ByteString' to write and a
'Timeout'. The function returns an 'IO' action which, when exectued, returns the
number of bytes that were actually written paired with a 'Status' flag which
indicates whether the transfer 'Completed' or 'TimedOut'.
-}
type WriteAction = B.ByteString → Timeout → IO (Size, Status)

-- | Handy type synonym for write transfers that must exactly write all the
-- given bytes. An 'incompleteWriteException' is thrown otherwise.
type WriteExactAction = B.ByteString → Timeout → IO ()

-- | Number of bytes transferred.
type Size = Int

-- | A timeout in milliseconds. A timeout defines how long a transfer should wait
-- before giving up due to no response being received.
-- Use 'noTimeout' for no timeout.
type Timeout = Int

-- | A timeout of 0 denotes no timeout so: @noTimeout = 0@.
noTimeout ∷ Timeout
noTimeout = 0

-- | Status of a terminated transfer.
data Status = Completed -- ^ All bytes were transferred
                        --   within the maximum allowed 'Timeout' period.
            | TimedOut  -- ^ Not all bytes were transferred
                        --   within the maximum allowed 'Timeout' period.
              deriving (COMMON_INSTANCES)

-------------------------------------------------------------------------------
-- ** Types of control transfers
-------------------------------------------------------------------------------

-- | Handy type synonym that names the parameters of a control transfer.
type ControlAction α = RequestType → Recipient → Request → Value → Index → α

data RequestType = Standard
                 | Class
                 | Vendor
                   deriving (Enum, COMMON_INSTANCES)

data Recipient = ToDevice
               | ToInterface
               | ToEndpoint
               | ToOther
                 deriving (Enum, COMMON_INSTANCES)

type Request = Word8

-- | (Host-endian)
type Value = Word16

-- | (Host-endian)
type Index = Word16

marshalRequestType ∷ RequestType → Recipient → Word8
marshalRequestType t r = genFromEnum t `shiftL` 5 .|. genFromEnum r

#ifdef HAS_EVENT_MANAGER
--------------------------------------------------------------------------------
-- ** Asynchronous device I/O
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- *** Control transfers
--------------------------------------------------------------------------------

controlSetupSize ∷ Size
controlSetupSize = sizeOf (undefined ∷ C'libusb_control_setup)

controlEndpoint ∷ CUChar
controlEndpoint = 0

controlAsync ∷ DeviceHandle → ControlAction (Timeout → IO ())
controlAsync devHndl = \reqType reqRecipient request value index → \timeout →
  allocaBytes controlSetupSize $ \bufferPtr → do
    poke bufferPtr $ C'libusb_control_setup
                       (marshalRequestType reqType reqRecipient)
                       request value index
                       0
    throwWhenTimedOut $ transferAsync c'LIBUSB_TRANSFER_TYPE_CONTROL
                                      devHndl
                                      controlEndpoint
                                      timeout
                                      (bufferPtr, controlSetupSize)

--------------------------------------------------------------------------------

readControlAsync ∷ DeviceHandle → ControlAction ReadAction
readControlAsync devHndl = \reqType reqRecipient request value index
                         → \size timeout → do
  let totalSize = controlSetupSize + size
  allocaBytes totalSize $ \bufferPtr → do
    poke bufferPtr $ C'libusb_control_setup
                       (setIn $ marshalRequestType reqType reqRecipient)
                       request value index
                       (fromIntegral size)
    (transferred, status) ← transferAsync c'LIBUSB_TRANSFER_TYPE_CONTROL
                                          devHndl controlEndpoint
                                          timeout
                                          (bufferPtr, totalSize)
    bs ← BI.create transferred $ \dataPtr →
           copyArray dataPtr (bufferPtr `plusPtr` controlSetupSize) transferred
    return (bs, status)

readControlExactAsync ∷ DeviceHandle → ControlAction ReadExactAction
readControlExactAsync = mkReadControlExact readControlAsync

--------------------------------------------------------------------------------

writeControlAsync ∷ DeviceHandle → ControlAction WriteAction
writeControlAsync devHndl = \reqType reqRecipient request value index
                          → \input timeout →
  BU.unsafeUseAsCStringLen input $ \(dataPtr, size) → do
    let totalSize = controlSetupSize + size
    allocaBytes totalSize $ \bufferPtr → do
      poke bufferPtr $ C'libusb_control_setup
                         (marshalRequestType reqType reqRecipient)
                         request value index
                         (fromIntegral size)
      copyArray (bufferPtr `plusPtr` controlSetupSize) dataPtr size
      transferAsync c'LIBUSB_TRANSFER_TYPE_CONTROL
                    devHndl controlEndpoint
                    timeout
                    (bufferPtr, totalSize)

writeControlExactAsync ∷ DeviceHandle → ControlAction WriteExactAction
writeControlExactAsync = mkWriteControlExact writeControlAsync

--------------------------------------------------------------------------------
-- *** Bulk / Interrupt transfers
--------------------------------------------------------------------------------

readBulkAsync,  readInterruptAsync  ∷ DeviceHandle → EndpointAddress → ReadAction
writeBulkAsync, writeInterruptAsync ∷ DeviceHandle → EndpointAddress → WriteAction

readBulkAsync       = readTransferAsync  c'LIBUSB_TRANSFER_TYPE_BULK
readInterruptAsync  = readTransferAsync  c'LIBUSB_TRANSFER_TYPE_INTERRUPT

writeBulkAsync      = writeTransferAsync c'LIBUSB_TRANSFER_TYPE_BULK
writeInterruptAsync = writeTransferAsync c'LIBUSB_TRANSFER_TYPE_INTERRUPT

readTransferAsync ∷ C'TransferType → DeviceHandle → EndpointAddress → ReadAction
readTransferAsync transType = \devHndl endpointAddr → \size timeout →
  createAndTrimNoOffset size $ \bufferPtr →
      transferAsync transType
                    devHndl (marshalEndpointAddress endpointAddr)
                    timeout
                    (bufferPtr, size)

writeTransferAsync ∷ C'TransferType → DeviceHandle → EndpointAddress → WriteAction
writeTransferAsync transType = \devHndl endpointAddr → \input timeout →
  BU.unsafeUseAsCStringLen input $
    transferAsync transType
                  devHndl (marshalEndpointAddress endpointAddr)
                  timeout

--------------------------------------------------------------------------------

type C'TransferType = CUChar

transferAsync ∷ C'TransferType
              → DeviceHandle → CUChar -- ^ Encoded endpoint address
              → Timeout
              → (Ptr byte, Size)
              → IO (Size, Status)
transferAsync transType devHndl endpoint timeout bytes =
    withTerminatedTransfer transType
                           0 []
                           devHndl endpoint
                           timeout
                           bytes $ \_ → curry return

--------------------------------------------------------------------------------

withTerminatedTransfer ∷ C'TransferType
                       → Int → [C'libusb_iso_packet_descriptor]
                       → DeviceHandle → CUChar -- ^ Encoded endpoint address
                       → Timeout
                       → (Ptr byte, Size)
                       → (Ptr C'libusb_transfer → Size → Status → IO α)
                       → IO α
withTerminatedTransfer transType
                       nrOfIsoPackets isoPackageDescs
                       devHndl endpoint
                       timeout
                       (bufferPtr, size)
                       convertResult =
   allocaTransfer nrOfIsoPackets $ \transPtr → do

     lock ← newLock
     withCallback (\_ → release lock) $ \cbPtr → do

       poke transPtr $ C'libusb_transfer
         { c'libusb_transfer'dev_handle      = getDevHndlPtr devHndl
         , c'libusb_transfer'flags           = 0 -- unused
         , c'libusb_transfer'endpoint        = endpoint
         , c'libusb_transfer'type            = transType
         , c'libusb_transfer'timeout         = fromIntegral timeout
         , c'libusb_transfer'status          = 0  -- output
         , c'libusb_transfer'length          = fromIntegral size
         , c'libusb_transfer'actual_length   = 0 -- output
         , c'libusb_transfer'callback        = cbPtr
         , c'libusb_transfer'user_data       = nullPtr -- unused
         , c'libusb_transfer'buffer          = castPtr bufferPtr
         , c'libusb_transfer'num_iso_packets = fromIntegral nrOfIsoPackets
         , c'libusb_transfer'iso_packet_desc = isoPackageDescs
         }

       -- Submit the transfer:
       mask_ $ do
         handleUSBException $ c'libusb_submit_transfer transPtr

         let Just (evtMgr, mbHandleEvents) = getEventManager $ getCtx $ getDevice devHndl
         case mbHandleEvents of
           Nothing → acquire lock
                       `onException`
                         (uninterruptibleMask_ $ do
                            _err ← c'libusb_cancel_transfer transPtr
                            acquire lock)
           Just handleEvents → do
             tk ← registerTimeout evtMgr (timeout * 1000) handleEvents
             acquire lock
               `onException`
                 (uninterruptibleMask_ $ do
                    unregisterTimeout evtMgr tk
                    _err ← c'libusb_cancel_transfer transPtr
                    acquire lock)

       trans ← peek transPtr

       let n = fromIntegral $ c'libusb_transfer'actual_length trans

       case c'libusb_transfer'status trans of
         ts | ts ≡ c'LIBUSB_TRANSFER_COMPLETED → convertResult transPtr n Completed
            | ts ≡ c'LIBUSB_TRANSFER_TIMED_OUT → convertResult transPtr n TimedOut

            | ts ≡ c'LIBUSB_TRANSFER_ERROR     → throwIO ioException
            | ts ≡ c'LIBUSB_TRANSFER_NO_DEVICE → throwIO NoDeviceException
            | ts ≡ c'LIBUSB_TRANSFER_OVERFLOW  → throwIO OverflowException
            | ts ≡ c'LIBUSB_TRANSFER_STALL     → throwIO PipeException

            | ts ≡ c'LIBUSB_TRANSFER_CANCELLED →
                moduleError "transfer status can't be Cancelled!"

            | otherwise → moduleError $ "Unknown transfer status: " ++ show ts ++ "!"

--------------------------------------------------------------------------------

allocaTransfer ∷ Int → (Ptr C'libusb_transfer → IO α) → IO α
allocaTransfer nrOfIsoPackets = bracket mallocTransfer c'libusb_free_transfer
    where
      mallocTransfer = do
        transPtr ← c'libusb_alloc_transfer (fromIntegral nrOfIsoPackets)
        when (transPtr ≡ nullPtr) (throwIO NoMemException)
        return transPtr

--------------------------------------------------------------------------------

newtype Lock = Lock (MVar ()) deriving Eq

newLock ∷ IO Lock
newLock = Lock <$> newEmptyMVar

acquire ∷ Lock → IO ()
acquire (Lock mv) = takeMVar mv

release ∷ Lock → IO ()
release (Lock mv) = putMVar mv ()

--------------------------------------------------------------------------------

withCallback ∷ (Ptr C'libusb_transfer → IO ())
             → (C'libusb_transfer_cb_fn → IO α)
             → IO α
withCallback callback = bracket (mkCallback callback) freeHaskellFunPtr

foreign import ccall "wrapper" mkCallback ∷ (Ptr C'libusb_transfer → IO ())
                                          → IO C'libusb_transfer_cb_fn

--------------------------------------------------------------------------------
-- *** Isochronous transfers
--------------------------------------------------------------------------------

{-| Perform a USB /isochronous/ read.

/WARNING:/ You need to enable the threaded runtime (@-threaded@) for this
function to work correctly. It throws a runtime error otherwise!

Exceptions:

 * 'PipeException' if the endpoint halted.

 * 'OverflowException' if the device offered more data,
   see /Packets and overflows/ in the @libusb@ documentation:
   <http://libusb.sourceforge.net/api-1.0/packetoverflow.html>.

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}
readIsochronous ∷ DeviceHandle
                → EndpointAddress
                → [Size] -- ^ Sizes of isochronous packets
                → Timeout
                → IO [B.ByteString]
readIsochronous devHndl endpointAddr sizes timeout
    | not threaded = needThreadedRTSError "readIsochronous"
    | otherwise    = do
  let SumLength totalSize nrOfIsoPackets = sumLength sizes
  allocaBytes totalSize $ \bufferPtr →
    withTerminatedTransfer c'LIBUSB_TRANSFER_TYPE_ISOCHRONOUS
                           nrOfIsoPackets (map initIsoPacketDesc sizes)
                           devHndl
                           (marshalEndpointAddress endpointAddr)
                           timeout
                           (bufferPtr, totalSize) $ \transPtr _ status → do
        case status of
          Completed → convertIsos nrOfIsoPackets transPtr bufferPtr
          TimedOut  → throwIO TimeoutException

--------------------------------------------------------------------------------

{-| Perform a USB /isochronous/ write.

/WARNING:/ You need to enable the threaded runtime (@-threaded@) for this
function to work correctly. It throws a runtime error otherwise!

Exceptions:

 * 'PipeException' if the endpoint halted.

 * 'OverflowException' if the device offered more data,
   see /Packets and overflows/ in the @libusb@ documentation:
   <http://libusb.sourceforge.net/api-1.0/packetoverflow.html>.

 * 'NoDeviceException' if the device has been disconnected.

 * Another 'USBException'.
-}
writeIsochronous ∷ DeviceHandle
                 → EndpointAddress
                 → [B.ByteString]
                 → Timeout
                 → IO [Size]
writeIsochronous devHndl endpointAddr isoPackets timeout
    | not threaded = needThreadedRTSError "writeIsochronous"
    | otherwise    = do
  let sizes = map B.length isoPackets
      SumLength totalSize nrOfIsoPackets = sumLength sizes
  allocaBytes totalSize $ \bufferPtr → do
    copyIsos (castPtr bufferPtr) isoPackets
    withTerminatedTransfer c'LIBUSB_TRANSFER_TYPE_ISOCHRONOUS
                           nrOfIsoPackets (map initIsoPacketDesc sizes)
                           devHndl
                           (marshalEndpointAddress endpointAddr)
                           timeout
                           (bufferPtr, totalSize) $ \transPtr _ status → do
      case status of
        Completed → map actualLength <$> peekIsoPacketDescs nrOfIsoPackets transPtr
        TimedOut  → throwIO TimeoutException

--------------------------------------------------------------------------------

actualLength ∷ C'libusb_iso_packet_descriptor → Size
actualLength = fromIntegral ∘ c'libusb_iso_packet_descriptor'actual_length

sumLength ∷ [Int] → SumLength
sumLength = foldl' (\(SumLength s l) x → SumLength (s+x) (l+1)) (SumLength 0 0)

data SumLength = SumLength !Int !Int

initIsoPacketDesc ∷ Size → C'libusb_iso_packet_descriptor
initIsoPacketDesc size =
    C'libusb_iso_packet_descriptor
    { c'libusb_iso_packet_descriptor'length        = fromIntegral size
    , c'libusb_iso_packet_descriptor'actual_length = 0
    , c'libusb_iso_packet_descriptor'status        = 0
    }

convertIsos ∷ Int → Ptr C'libusb_transfer → Ptr Word8 → IO [B.ByteString]
convertIsos nrOfIsoPackets transPtr bufferPtr =
    peekIsoPacketDescs nrOfIsoPackets transPtr >>= go bufferPtr id
      where
        go _   bss [] = return $ bss []
        go ptr bss (C'libusb_iso_packet_descriptor l a _ : ds) = do
          let transferred = fromIntegral a
          bs ← BI.create transferred $ \p → copyArray p ptr transferred
          go (ptr `plusPtr` fromIntegral l) ((bs:) ∘ bss) ds

peekIsoPacketDescs ∷ Int
                   → Ptr C'libusb_transfer
                   → IO [C'libusb_iso_packet_descriptor]
peekIsoPacketDescs nrOfIsoPackets = peekArray nrOfIsoPackets
                                  ∘ p'libusb_transfer'iso_packet_desc

copyIsos ∷ Ptr CChar → [B.ByteString] → IO ()
copyIsos _ [] = return ()
copyIsos bufferPtr (bs:bss) = do
  let l = B.length bs
  BU.unsafeUseAsCString bs $ \ptr → copyArray bufferPtr ptr l
  copyIsos (bufferPtr `plusPtr` l) bss

#endif
--------------------------------------------------------------------------------
-- ** Common utilities for both the asynchronous and synchronous implementation
--------------------------------------------------------------------------------

setIn ∷ Word8 → Word8
setIn = (`setBit` 7)

throwWhenTimedOut ∷ IO (Size, Status) → IO ()
throwWhenTimedOut doTransfer = do
  (_, status) ← doTransfer
  when (status ≡ TimedOut) $ throwIO TimeoutException

mkReadControlExact ∷ (DeviceHandle → ControlAction ReadAction)
                   → (DeviceHandle → ControlAction ReadExactAction)
mkReadControlExact readControl = \devHndl
                               → \reqType reqRecipient request value index
                               → \size timeout → do
  (bs, _) ← readControl devHndl
                        reqType reqRecipient request value index
                        size timeout
  if B.length bs ≢ size
    then throwIO incompleteReadException
    else return bs

mkWriteControlExact ∷ (DeviceHandle → ControlAction WriteAction)
                    → (DeviceHandle → ControlAction WriteExactAction)
mkWriteControlExact writeControl = \devHndl
                                 → \reqType reqRecipient request value index
                                 → \input timeout → do
  (transferred, _) ← writeControl devHndl
                                  reqType reqRecipient request value index
                                  input timeout
  when (transferred ≢ B.length input) $ throwIO incompleteWriteException

createAndTrimNoOffset ∷ Size → (Ptr Word8 → IO (Size, α)) → IO (B.ByteString, α)
createAndTrimNoOffset size f = BI.createAndTrim' size $ \ptr → do
                                 (l, x) ← f ptr
                                 return (offset, l, x)
                                     where
                                       offset = 0

--------------------------------------------------------------------------------
-- ** Synchronous device I/O
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- *** Control transfers
--------------------------------------------------------------------------------

controlSync ∷ DeviceHandle → ControlAction (Timeout → IO ())
controlSync devHndl = \reqType reqRecipient request value index
                    → \timeout →
    throwWhenTimedOut $ controlTransferSync
                          devHndl
                          (marshalRequestType reqType reqRecipient)
                          request value index
                          timeout
                          (nullPtr, 0)

readControlSync ∷ DeviceHandle → ControlAction ReadAction
readControlSync devHndl = \reqType reqRecipient request value index
                        → \size timeout →
    createAndTrimNoOffset size $ \dataPtr →
        controlTransferSync
          devHndl
          (setIn $ marshalRequestType reqType reqRecipient)
          request value index
          timeout
          (dataPtr, size)

readControlExactSync ∷ DeviceHandle → ControlAction ReadExactAction
readControlExactSync = mkReadControlExact readControlSync

writeControlSync ∷ DeviceHandle → ControlAction WriteAction
writeControlSync devHndl = \reqType reqRecipient request value index
                         → \input timeout →
    BU.unsafeUseAsCStringLen input $
      controlTransferSync
        devHndl
        (marshalRequestType reqType reqRecipient)
        request value index
        timeout

writeControlExactSync ∷ DeviceHandle → ControlAction WriteExactAction
writeControlExactSync = mkWriteControlExact writeControlSync

controlTransferSync ∷ DeviceHandle
                    → Word8 → Request → Value → Index
                    → Timeout
                    → (Ptr byte, Size)
                    → IO (Size, Status)
controlTransferSync devHndl = \reqType request value index
                            → \timeout
                            → \(dataPtr, size) → do
      err ← c'libusb_control_transfer
              (getDevHndlPtr devHndl)
              reqType request value index
              (castPtr dataPtr) (fromIntegral size)
              (fromIntegral timeout)
      let timedOut = err ≡ c'LIBUSB_ERROR_TIMEOUT
      if err < 0 ∧ not timedOut
        then throwIO $ convertUSBException err
        else return ( fromIntegral err
                    , if timedOut then TimedOut else Completed
                    )

--------------------------------------------------------------------------------
-- *** Bulk / Interrupt
--------------------------------------------------------------------------------

readBulkSync,  readInterruptSync  ∷ DeviceHandle → EndpointAddress → ReadAction
writeBulkSync, writeInterruptSync ∷ DeviceHandle → EndpointAddress → WriteAction

readBulkSync       = readTransferSync  c'libusb_bulk_transfer
readInterruptSync  = readTransferSync  c'libusb_interrupt_transfer

writeBulkSync      = writeTransferSync c'libusb_bulk_transfer
writeInterruptSync = writeTransferSync c'libusb_interrupt_transfer

--------------------------------------------------------------------------------

-- | Handy type synonym for the @libusb@ transfer functions.
type C'TransferFunc = Ptr C'libusb_device_handle -- devHndlPtr
                    → CUChar                     -- endpoint address
                    → Ptr CUChar                 -- dataPtr
                    → CInt                       -- size
                    → Ptr CInt                   -- transferredPtr
                    → CUInt                      -- timeout
                    → IO CInt                    -- error

readTransferSync ∷ C'TransferFunc → (DeviceHandle → EndpointAddress → ReadAction)
readTransferSync c'transfer = \devHndl endpointAddr → \size timeout →
    createAndTrimNoOffset size $ \dataPtr →
        transferSync c'transfer
                     devHndl endpointAddr
                     timeout
                     (castPtr dataPtr, size)

writeTransferSync ∷ C'TransferFunc → (DeviceHandle → EndpointAddress → WriteAction)
writeTransferSync c'transfer = \devHndl endpointAddr → \input timeout →
    BU.unsafeUseAsCStringLen input $
      transferSync c'transfer
                   devHndl endpointAddr
                   timeout

transferSync ∷ C'TransferFunc → DeviceHandle
                              → EndpointAddress
                              → Timeout
                              → CStringLen
                              → IO (Size, Status)
transferSync c'transfer devHndl
                        endpointAddr
                        timeout
                        (dataPtr, size) =
    alloca $ \transferredPtr → do
      err ← c'transfer (getDevHndlPtr devHndl)
                       (marshalEndpointAddress endpointAddr)
                       (castPtr dataPtr)
                       (fromIntegral size)
                       transferredPtr
                       (fromIntegral timeout)
      let timedOut = err ≡ c'LIBUSB_ERROR_TIMEOUT
      if err ≢ c'LIBUSB_SUCCESS ∧ not timedOut
        then throwIO $ convertUSBException err
        else do transferred ← peek transferredPtr
                return ( fromIntegral transferred
                       , if timedOut then TimedOut else Completed
                       )

--------------------------------------------------------------------------------
-- * Exceptions
--------------------------------------------------------------------------------

-- | @handleUSBException action@ executes @action@. If @action@ returned an
-- error code other than 'c\'LIBUSB_SUCCESS', the error is converted to a
-- 'USBException' and thrown.
handleUSBException ∷ IO CInt → IO ()
handleUSBException action = do err ← action
                               when (err ≢ c'LIBUSB_SUCCESS)
                                    (throwIO $ convertUSBException err)

-- | @checkUSBException action@ executes @action@. If @action@ returned a
-- negative integer the integer is converted to a 'USBException' and thrown. If
-- not, the integer is returned.
checkUSBException ∷ Integral α ⇒ IO α → IO Int
checkUSBException action = do r ← action
                              if r < 0
                                then throwIO $ convertUSBException r
                                else return $ fromIntegral r

-- | Convert a @C'libusb_error@ to a 'USBException'. If the @C'libusb_error@ is
-- unknown an 'error' is thrown.
convertUSBException ∷ Num α ⇒ α → USBException
convertUSBException err = fromMaybe unknownLibUsbError $
                            lookup err libusb_error_to_USBException
    where
      unknownLibUsbError =
        moduleError $ "Unknown libusb error code: " ++ show err ++ "!"

-- | Association list mapping 'C'libusb_error's to 'USBException's.
libusb_error_to_USBException ∷ Num α ⇒ [(α, USBException)]
libusb_error_to_USBException =
    [ (c'LIBUSB_ERROR_IO,            ioException)
    , (c'LIBUSB_ERROR_INVALID_PARAM, InvalidParamException)
    , (c'LIBUSB_ERROR_ACCESS,        AccessException)
    , (c'LIBUSB_ERROR_NO_DEVICE,     NoDeviceException)
    , (c'LIBUSB_ERROR_NOT_FOUND,     NotFoundException)
    , (c'LIBUSB_ERROR_BUSY,          BusyException)
    , (c'LIBUSB_ERROR_TIMEOUT,       TimeoutException)
    , (c'LIBUSB_ERROR_OVERFLOW,      OverflowException)
    , (c'LIBUSB_ERROR_PIPE,          PipeException)
    , (c'LIBUSB_ERROR_INTERRUPTED,   InterruptedException)
    , (c'LIBUSB_ERROR_NO_MEM,        NoMemException)
    , (c'LIBUSB_ERROR_NOT_SUPPORTED, NotSupportedException)
    , (c'LIBUSB_ERROR_OTHER,         OtherException)
    ]

-- | Type of USB exceptions.
data USBException =
   IOException String    -- ^ Input/output exception.
 | InvalidParamException -- ^ Invalid parameter.
 | AccessException       -- ^ Access denied (insufficient permissions). It may
                         --   help to run your program with elevated privileges or
                         --   change the permissions of your device using
                         --   something like @udev@.
 | NoDeviceException     -- ^ No such device (it may have been disconnected).
 | NotFoundException     -- ^ Entity not found.
 | BusyException         -- ^ Resource busy.
 | TimeoutException      -- ^ Operation timed out.
 | OverflowException     -- ^ If the device offered to much data.
                         --   See /Packets and overflows/ in the @libusb@ documentation:
                         --   <http://libusb.sourceforge.net/api-1.0/packetoverflow.html>
 | PipeException         -- ^ Pipe exception.
 | InterruptedException  -- ^ System call interrupted (perhaps due to signal).
 | NoMemException        -- ^ Insufficient memory.
 | NotSupportedException -- ^ Operation not supported or unimplemented on this
                         --   platform.
 | OtherException        -- ^ Other exception.
   deriving (COMMON_INSTANCES)

instance Exception USBException

-- | A general 'IOException'.
ioException ∷ USBException
ioException = IOException ""

-- | 'IOException' that is thrown when the number of bytes /read/
-- doesn't equal the requested number.
incompleteReadException ∷ USBException
incompleteReadException = incompleteException "read"

-- | 'IOException' that is thrown when the number of bytes /written/
-- doesn't equal the requested number.
incompleteWriteException ∷ USBException
incompleteWriteException = incompleteException "written"

incompleteException ∷ String → USBException
incompleteException rw = IOException $
    "The number of bytes " ++ rw ++ " doesn't equal the requested number!"

--------------------------------------------------------------------------------

moduleError ∷ String → error
moduleError msg = error $ thisModule ++ ": " ++ msg

thisModule ∷ String
thisModule = "System.USB.Internal"

needThreadedRTSError ∷ String → error
needThreadedRTSError msg = moduleError $ msg ++
  " is only supported when using the threaded runtime. " ++
  "Please build your program with -threaded."
