#import "global.h"
#import "LowLevelWindow_Cocoa.h"
#import "DisplayResolutions.h"
#import "RageUtil.h"
#import "RageThreads.h"
#import "RageDisplay_OGL_Helpers.h"
#import "arch/ArchHooks/ArchHooks.h"
#import "archutils/Darwin/SMMainThread.h"

#import <Cocoa/Cocoa.h>
#import <OpenGl/OpenGl.h>
#import <OpenGL/gl.h>
#import <mach-o/dyld.h>

// Bad header!
extern "C" {
#include <IOKit/graphics/IOGraphicsLib.h>
}


static const unsigned int g_iStyleMask = NSTitledWindowMask | NSClosableWindowMask |
					 NSMiniaturizableWindowMask | NSResizableWindowMask;
static bool g_bResized;
static int g_iWidth;
static int g_iHeight;
static RageMutex g_ResizeLock( "Window resize lock." );

// Simple helper class
class AutoreleasePool
{
	AutoreleasePool( const AutoreleasePool& );
	AutoreleasePool &operator=( const AutoreleasePool& );
	NSAutoreleasePool *m_Pool;
	
public:
	AutoreleasePool() { m_Pool = [[NSAutoreleasePool alloc] init]; }
	~AutoreleasePool() { [m_Pool release]; }
};

#define POOL AutoreleasePool UNIQUE_NAME(pool)

// Window delegate class
@interface SMWindowDelegate : NSObject
- (void) windowDidBecomeKey:(NSNotification *)aNotification;
- (void) windowDidResignKey:(NSNotification *)aNotification;
- (void) windowWillClose:(NSNotification *)aNotification;
- (void) windowDidResize:(NSNotification *)aNotification;
// XXX maybe use whichever screen contains the window? Hard for me to test though.
//- (void) windowDidChangeScreen:(NSNotification *)aNotification;
@end

@implementation SMWindowDelegate
- (void) windowDidBecomeKey:(NSNotification *)aNotification
{
	HOOKS->SetHasFocus( true );
}

- (void) windowDidResignKey:(NSNotification *)aNotification
{
	HOOKS->SetHasFocus( false );
}

- (void) windowWillClose:(NSNotification *)aNotification
{
	ArchHooks::SetUserQuit();
}

- (void) windowDidResize:(NSNotification *)aNotification
{
	id window = [aNotification object];
	NSSize size = [NSWindow contentRectForFrameRect:[window frame] styleMask:g_iStyleMask].size;
	
	LockMut( g_ResizeLock );
	g_bResized = true;
	g_iWidth = int( size.width );
	g_iHeight = int( size.height );
}
@end

enum GLContextType
{
	WINDOWED,
	FULL_SCREEN,
	PIXEL_BUFFER
};

static NSOpenGLContext *CreateOGLContext( GLContextType type, int iColorSize, int iAlphaSize, int iDepthSize, NSOpenGLContext *share, bool &bShared )
{
	NSOpenGLPixelFormatAttribute attrs[] = {
		NSOpenGLPFANoRecovery, // so we can share with the full screen context
		NSOpenGLPFAAccelerated,
		NSOpenGLPFAMinimumPolicy,
		NSOpenGLPFAColorSize, NSOpenGLPixelFormatAttribute(iColorSize),
		NSOpenGLPFAAlphaSize, NSOpenGLPixelFormatAttribute(iAlphaSize),
		NSOpenGLPFADepthSize, NSOpenGLPixelFormatAttribute(iDepthSize),
		NSOpenGLPixelFormatAttribute(0), // 9
		NSOpenGLPixelFormatAttribute(0), // 10
		NSOpenGLPixelFormatAttribute(0), // 11
		NSOpenGLPixelFormatAttribute(0), // 12
		NSOpenGLPixelFormatAttribute(0)  // Must be at the end.
	};
	const int n = 9; // The first noncommon index.
	
	switch( type )
	{
	case WINDOWED:
		attrs[n+0] = NSOpenGLPFAWindow;
		attrs[n+1] = NSOpenGLPFADoubleBuffer;
		break;
	case FULL_SCREEN:
		attrs[n+0] = NSOpenGLPFAFullScreen;
		attrs[n+1] = NSOpenGLPFADoubleBuffer;
		attrs[n+2] = NSOpenGLPFAScreenMask;
		attrs[n+3] = NSOpenGLPixelFormatAttribute( CGDisplayIDToOpenGLDisplayMask(kCGDirectMainDisplay) );
		break;
	case PIXEL_BUFFER:
		attrs[n+0] = NSOpenGLPFAOffScreen;
		attrs[n+1] = NSOpenGLPFAPixelBuffer;
		break;
	}
	
	NSOpenGLPixelFormat *pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
	
	if( !pixelFormat )
		return nil;
	
	NSOpenGLContext *context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:share];
	
	bShared = share && context;
	if( !context )
		context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
	
	[pixelFormat release];
	
	return context;
}		


class RenderTarget_Cocoa : public RenderTarget
{
public:
	RenderTarget_Cocoa( id shareContext );
	~RenderTarget_Cocoa();
	void Create( const RenderTargetParam &param, int &iTextureWidthOut, int &iTextureHeightOut );
	unsigned GetTexture() const { return m_iTexHandle; }
	void StartRenderingTo();
	void FinishRenderingTo();
	
private:
	NSOpenGLContext *m_ShareContext, *m_OldContext, *m_PBufferContext;
	GLuint m_iTexHandle;
	int m_iWidth, m_iHeight;
};

RenderTarget_Cocoa::RenderTarget_Cocoa( id shareContext )
{
	m_ShareContext = shareContext;
	m_OldContext = nil;
	m_PBufferContext = nil;
	m_iTexHandle = 0;
	m_iWidth = 0;
	m_iHeight = 0;
}

RenderTarget_Cocoa::~RenderTarget_Cocoa()
{
	POOL;
	[m_PBufferContext release];
	if( m_iTexHandle )
		glDeleteTextures( 1, &m_iTexHandle );
}

void RenderTarget_Cocoa::Create( const RenderTargetParam &param, int &iTextureWidthOut, int &iTextureHeightOut )
{
	POOL;
	m_iWidth = param.iWidth;
	m_iHeight = param.iHeight;
	
	// PBuffer needs to be a power of 2.
	int iTextureWidth = power_of_two( param.iWidth );
	int iTextureHeight = power_of_two( param.iHeight );

	// Create the PBuffer.
	unsigned long format = param.bWithAlpha? GL_RGBA:GL_RGB;
	NSOpenGLPixelBuffer *PBuffer = [[NSOpenGLPixelBuffer alloc] initWithTextureTarget:GL_TEXTURE_2D
								    textureInternalFormat:format
								    textureMaxMipMapLevel:0 // No idea.
									       pixelsWide:iTextureWidth
									       pixelsHigh:iTextureHeight];
	DEBUG_ASSERT( PBuffer );
	
	// Create an OGL context.
	bool bShared = false;
	m_PBufferContext = CreateOGLContext( PIXEL_BUFFER, 24, param.bWithAlpha? 8:0, param.bWithDepthBuffer? 16:0, m_ShareContext, bShared );
	DEBUG_ASSERT( m_PBufferContext );
	DEBUG_ASSERT( bShared );
	[m_PBufferContext setPixelBuffer:PBuffer cubeMapFace:0 mipMapLevel:0
		    currentVirtualScreen:[m_ShareContext currentVirtualScreen]];
	[PBuffer release]; // XXX: Hopefully this is retained by the PBufferContext.
	
	glGenTextures( 1, &m_iTexHandle );
	glBindTexture( GL_TEXTURE_2D, m_iTexHandle );
	
	while( glGetError() != GL_NO_ERROR )
		;
	
	iTextureWidthOut = iTextureWidth;
	iTextureHeightOut = iTextureHeight;
	
	glTexImage2D( GL_TEXTURE_2D, 0, param.bWithAlpha? GL_RGBA8:GL_RGB8,
		      iTextureWidth, iTextureHeight, 0, param.bWithAlpha? GL_RGBA:GL_RGB,
		      GL_UNSIGNED_BYTE, NULL );
	GLenum error = glGetError();
	ASSERT_M( error == GL_NO_ERROR, RageDisplay_OGL_Helpers::GLToString(error) );
	
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
}

void RenderTarget_Cocoa::StartRenderingTo()
{
	DEBUG_ASSERT( !m_OldContext );
	m_OldContext = [NSOpenGLContext currentContext];
	[m_PBufferContext makeCurrentContext];
	glViewport( 0, 0, m_iWidth, m_iHeight );
}

void RenderTarget_Cocoa::FinishRenderingTo()
{
	DEBUG_ASSERT( m_OldContext );
	glFlush();
	glBindTexture( GL_TEXTURE_2D, m_iTexHandle );
	
	while( glGetError() != GL_NO_ERROR )
		;
	
	glCopyTexSubImage2D( GL_TEXTURE_2D, 0, 0, 0, 0, 0, m_iWidth, m_iHeight );
	
	GLenum error = glGetError();
	ASSERT_M( error == GL_NO_ERROR, RageDisplay_OGL_Helpers::GLToString(error) );
	
	glBindTexture( GL_TEXTURE_2D, 0 );
	
	[m_OldContext makeCurrentContext];
	m_OldContext = nil;
}

LowLevelWindow_Cocoa::LowLevelWindow_Cocoa() : m_Context(nil), m_BGContext(nil), m_CurrentDisplayMode(NULL)
{
	POOL;
	NSRect rect = { {0, 0}, {0, 0} };
	SMMainThread *mt = [[SMMainThread alloc] init];
	
	m_Window = [[NSWindow alloc] initWithContentRect:rect
					       styleMask:g_iStyleMask
						 backing:NSBackingStoreBuffered
						   defer:YES];
	
	ADD_ACTIONb( mt, m_Window, setExcludedFromWindowsMenu:, YES );
	ADD_ACTIONb( mt, m_Window, useOptimizedDrawing:, YES );
	ADD_ACTIONb( mt, m_Window, setReleasedWhenClosed:, NO );
	// setDelegate: does not retain the delegate; however, we don't (auto)release it.
	ADD_ACTION1( mt, m_Window, setDelegate:, [[SMWindowDelegate alloc] init] );
	
	[mt performOnMainThread];
	[mt release];
	m_CurrentParams.windowed = true; // We are essentially windowed to begin with.
	SetActualParamsFromMode( CGDisplayCurrentMode(kCGDirectMainDisplay) );
	HOOKS->SetHasFocus( [NSApp isActive] );
}

LowLevelWindow_Cocoa::~LowLevelWindow_Cocoa()
{
	POOL;
	ShutDownFullScreen();
	
	SMMainThread *mt = [[SMMainThread alloc] init];
	
	// We need to release the window's delegate now.
	id delegate = [m_Window delegate];
	
	ADD_ACTION1( mt, m_Window, setDelegate:, nil );
	ADD_ACTION1( mt, m_Window, orderOut:, nil );
	ADD_ACTION0( mt, m_Window, release );
	
	[m_Context clearDrawable];
	[m_Context release];
	[m_BGContext clearDrawable];
	[m_BGContext release];
	[mt performOnMainThread];
	[delegate release];
	[mt release];
}

void *LowLevelWindow_Cocoa::GetProcAddress( RString s )
{
	// http://developer.apple.com/qa/qa2001/qa1188.html
	// Both functions mentioned in there are deprecated in 10.4.
	const RString& symbolName( '_' + s );
	const uint32_t count = _dyld_image_count();
	NSSymbol symbol = NULL;
	const uint32_t options = NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR;
	
	for( uint32_t i = 0; i < count && !symbol; ++i )
		symbol = NSLookupSymbolInImage( _dyld_get_image_header(i), symbolName, options );
	return symbol ? NSAddressOfSymbol( symbol ) : NULL;
}

RString LowLevelWindow_Cocoa::TryVideoMode( const VideoModeParams& p, bool& newDeviceOut )
{
	// Always set these params.
	m_CurrentParams.bSmoothLines = p.bSmoothLines;
	m_CurrentParams.bTrilinearFiltering = p.bTrilinearFiltering;
	m_CurrentParams.bAnisotropicFiltering = p.bAnisotropicFiltering;
	m_CurrentParams.interlaced = p.interlaced;
	m_CurrentParams.PAL = p.PAL;
	m_CurrentParams.fDisplayAspectRatio = p.fDisplayAspectRatio;
	
#define X(x) p.x != m_CurrentParams.x
	const bool bRebuildContext = X(bpp) || X(windowed) || !m_Context;
	const bool bChangeMode = X(width) || X(height) || X(rate) || bRebuildContext;
	const bool bChangeVsync = X(vsync) || bRebuildContext;
#undef X
	
	if( !bChangeMode && !bChangeVsync )
		return RString();
	
	POOL;
	newDeviceOut = false;
	
	NSRect contentRect = { { 0, 0 }, { p.width, p.height } };	
	
	ASSERT( p.bpp == 16 || p.bpp == 32 );
	
	// If we don't have focus, we cannot be full screen.
	if( p.windowed || !HOOKS->AppHasFocus() )
	{		
		if( bRebuildContext )
		{
			bool bShared;
			NSOpenGLContext *newContext = CreateOGLContext( WINDOWED, p.bpp == 16? 16:24, p.bpp == 16? 1:8, 16, m_Context, bShared );
			
			if( !newContext )
				return "Failed to create OGL context.";
			ShutDownFullScreen();
			[m_Context release];
			m_Context = newContext;
			newDeviceOut = !bShared;
			m_CurrentParams.bpp = p.bpp;
			[m_BGContext release];
			m_BGContext = nil;
			m_BGContext = CreateOGLContext( WINDOWED, p.bpp == 16? 16:24, p.bpp == 16? 1:8, 16, m_Context, bShared );
			
			if( m_BGContext && !bShared )
			{
				[m_BGContext release];
				m_BGContext = nil;
			}
		}
		SMMainThread *mt = [[SMMainThread alloc] init];
		
		// Change the window and the title
		ADD_ACTIONn( mt, m_Window, setContentSize:, 1, &contentRect.size );
		ADD_ACTION1( mt, m_Window, setTitle:, [NSString stringWithUTF8String:p.sWindowTitle.c_str()] );		
		ADD_ACTION0( mt, m_Window, center );
		ADD_ACTION1( mt, m_Window, makeKeyAndOrderFront:, nil );
		
		[mt performOnMainThread];
		[mt release];
		[m_Context setView:[m_Window contentView]];
		[m_Context update];
		[m_Context makeCurrentContext];
		m_CurrentParams.windowed = true;
		SetActualParamsFromMode( CGDisplayCurrentMode(kCGDirectMainDisplay) );
		m_CurrentParams.vsync = p.vsync; // hack

		return RString();
	}
	if( bChangeMode )
	{
		int result = ChangeDisplayMode( p );
	
		if( result )
			return ssprintf( "Failed to switch to full screen:%d x %d @ %d. Error %d.",
					 p.width, p.height, p.rate, result );
	}

	if( bRebuildContext )
	{
		bool bShared;
		NSOpenGLContext *newContext = CreateOGLContext( FULL_SCREEN, p.bpp == 16? 16:24, p.bpp == 16? 1:8, 16, m_Context, bShared );
		
		if( !newContext )
			return "Failed to create full screen OGL context.";
		[m_Context clearDrawable];
		[m_Context release];
		m_Context = newContext;
		newDeviceOut = !bShared;
		m_CurrentParams.bpp = p.bpp;
		[m_BGContext release];
		m_BGContext = CreateOGLContext( FULL_SCREEN, p.bpp == 16? 16:24, p.bpp == 16? 1:8, 16, m_Context, bShared );
		
		if( m_BGContext && !bShared )
		{
			[m_BGContext release];
			m_BGContext = nil;
		}
	}
	
	[m_Context setFullScreen];
	[m_Context update];
	[m_Context makeCurrentContext];
	
	if( bChangeVsync )
	{
		long swap = p.vsync ? 1 : 0;

		[m_Context setValues:&swap forParameter:NSOpenGLCPSwapInterval];
		m_CurrentParams.vsync = p.vsync;
	}
	
	return RString();
}

void LowLevelWindow_Cocoa::ShutDownFullScreen()
{
	if( m_CurrentParams.windowed )
		return;
	ASSERT( m_CurrentDisplayMode );
	
	// Clear the front and back framebuffers before switching out of FullScreen mode.
	// (This is not strictly necessary, but avoids an untidy flash of garbage.)
	glClearColor( 0.0f, 0.0f, 0.0f, 0.0f );
	glClear( GL_COLOR_BUFFER_BIT );
	[m_Context flushBuffer];
	glClear( GL_COLOR_BUFFER_BIT );
	[m_Context flushBuffer];	
	
	[NSOpenGLContext clearCurrentContext];
	[m_Context clearDrawable];
	[m_BGContext clearDrawable];
	
	CGDisplayErr err = CGDisplaySwitchToMode( kCGDirectMainDisplay, m_CurrentDisplayMode );
	
	ASSERT( err == kCGErrorSuccess );
	CGDisplayShowCursor( kCGDirectMainDisplay );
	err = CGReleaseAllDisplays();
	ASSERT( err == kCGErrorSuccess );
	SetActualParamsFromMode( m_CurrentDisplayMode );
	// We don't own this so we cannot release it.
	m_CurrentDisplayMode = NULL;
	m_CurrentParams.windowed = true;
}

int LowLevelWindow_Cocoa::ChangeDisplayMode( const VideoModeParams& p )
{	
	CFDictionaryRef mode = NULL;
	CFDictionaryRef newMode;
	CGDisplayErr err;
	
	if( !m_CurrentDisplayMode )
	{
		if( (err = CGCaptureAllDisplays()) != kCGErrorSuccess )
			return err;
		// Only hide the first time we go to full screen.
		CGDisplayHideCursor( kCGDirectMainDisplay );	
		mode = CGDisplayCurrentMode( kCGDirectMainDisplay );
	}
	
	if( p.rate == REFRESH_DEFAULT )
		newMode = CGDisplayBestModeForParameters( kCGDirectMainDisplay, p.bpp, p.width, p.height, NULL );
	else
		newMode = CGDisplayBestModeForParametersAndRefreshRate( kCGDirectMainDisplay, p.bpp,
									p.width, p.height, p.rate, NULL );
	
	
	err = CGDisplaySwitchToMode( kCGDirectMainDisplay, newMode );
	
	if( err != kCGErrorSuccess )
		return err; // We don't own mode, don't release it.
	
	if( !m_CurrentDisplayMode )
		m_CurrentDisplayMode = mode;
	m_CurrentParams.windowed = false;
	SetActualParamsFromMode( newMode );
	
	return 0;
}

void LowLevelWindow_Cocoa::SetActualParamsFromMode( CFDictionaryRef mode )
{
	SInt32 rate;
	bool ret = CFNumberGetValue( (CFNumberRef)CFDictionaryGetValue(mode, CFSTR("RefreshRate")),
				     kCFNumberSInt32Type, &rate );
	
	if( !ret || rate == 0)
		rate = 60;
	m_CurrentParams.rate = rate;

	if( !m_CurrentParams.windowed )
	{
		long swap;

		m_CurrentParams.width = CGDisplayPixelsWide( kCGDirectMainDisplay );
		m_CurrentParams.height = CGDisplayPixelsHigh( kCGDirectMainDisplay );
		CGLGetParameter( CGLGetCurrentContext(), kCGLCPSwapInterval, &swap );
		m_CurrentParams.vsync = swap != 0;
	}
	else
	{
		NSSize size = [[m_Window contentView] frame].size;
		
		m_CurrentParams.width = int(size.width);
		m_CurrentParams.height = int(size.height);
	}

	m_CurrentParams.bpp = CGDisplayBitsPerPixel( kCGDirectMainDisplay );
}

static int GetIntValue( CFTypeRef r )
{
	int ret;
	
	if( !r || CFGetTypeID(r) != CFNumberGetTypeID() || !CFNumberGetValue(CFNumberRef(r), kCFNumberIntType, &ret) )
		return 0;
	return ret;
}

static bool GetBoolValue( CFTypeRef r )
{
	return r && CFGetTypeID( r ) == CFBooleanGetTypeID() && CFBooleanGetValue( CFBooleanRef(r) );
}

void LowLevelWindow_Cocoa::GetDisplayResolutions( DisplayResolutions &dr ) const
{
	CFArrayRef modes = CGDisplayAvailableModes( kCGDirectMainDisplay );
	ASSERT( modes );
	const CFIndex count = CFArrayGetCount( modes );
	
	for( CFIndex i = 0; i < count; ++i )
	{
		CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex( modes, i );
		int width = GetIntValue( CFDictionaryGetValue(dict, kCGDisplayWidth) );
		int height = GetIntValue( CFDictionaryGetValue(dict, kCGDisplayHeight) );
		CFTypeRef safe = CFDictionaryGetValue( dict, kCGDisplayModeIsSafeForHardware );
		bool stretched = GetBoolValue( CFDictionaryGetValue(dict, kCGDisplayModeIsStretched) );
		
		if( !width || !height )
			continue;
		if( safe && !GetBoolValue( safe ) )
			continue;
		DisplayResolution res = { width, height, stretched };
		dr.insert( res );
	}
	// Do not release modes! We don't own them here.
}

float LowLevelWindow_Cocoa::GetMonitorAspectRatio() const
{
	io_connect_t displayPort = CGDisplayIOServicePort( CGMainDisplayID() );
	CFDictionaryRef dict = IODisplayCreateInfoDictionary( displayPort, 0 );
	int width = GetIntValue( CFDictionaryGetValue(dict, CFSTR(kDisplayHorizontalImageSize)) );
	int height = GetIntValue( CFDictionaryGetValue(dict, CFSTR(kDisplayVerticalImageSize)) );
	
	CFRelease( dict );
	
	if( width && height )
		return float(width)/height;
	return 4/3.f;
}

void LowLevelWindow_Cocoa::SwapBuffers()
{
	CGLFlushDrawable( CGLGetCurrentContext() );
}

void LowLevelWindow_Cocoa::Update()
{
	// Keep the system from sleeping or the screen saver from activating.
	UpdateSystemActivity( IdleActivity );
	
	LockMutex lock( g_ResizeLock );
	if( likely(!g_bResized) )
		return;
	g_bResized = false;
	if( m_CurrentParams.width == g_iWidth && m_CurrentParams.height == g_iHeight )
		return;
	m_CurrentParams.width = g_iWidth;
	m_CurrentParams.height = g_iHeight;
	lock.Unlock(); // Unlock before calling ResolutionChanged().
	[m_Context update];
	DISPLAY->ResolutionChanged();
}

RenderTarget *LowLevelWindow_Cocoa::CreateRenderTarget()
{
	return new RenderTarget_Cocoa( m_Context );
}

void LowLevelWindow_Cocoa::BeginConcurrentRendering()
{
	if( m_CurrentParams.windowed )
		[m_BGContext setView:[m_Window contentView]];
	else
		[m_BGContext setFullScreen];
	[m_BGContext makeCurrentContext];
}

/*
 * (c) 2005-2006 Steve Checkoway
 * All rights reserved.
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, and/or sell copies of the Software, and to permit persons to
 * whom the Software is furnished to do so, provided that the above
 * copyright notice(s) and this permission notice appear in all copies of
 * the Software and that both the above copyright notice(s) and this
 * permission notice appear in supporting documentation.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
 * THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
 * INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */

