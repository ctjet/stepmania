#include "global.h"
#include "ScreenSystemLayer.h"
#include "PrefsManager.h"
#include "ThemeManager.h"
#include "ActorUtil.h"
#include "GameState.h"
#include "MemoryCardManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageDisplay.h"
#include "RageLog.h"
#include "Command.h"


REGISTER_SCREEN_CLASS( ScreenSystemLayer );
ScreenSystemLayer::ScreenSystemLayer( const CString &sName ) : Screen(sName)
{
	MESSAGEMAN->Subscribe( this, "RefreshCreditText" );
	MESSAGEMAN->Subscribe( this, "SystemMessage" );
	MESSAGEMAN->Subscribe( this, "SystemMessageNoAnimate" );

	CREDITS_PRESS_START.Load("ScreenSystemLayer","CreditsPressStart");
	CREDITS_INSERT_CARD.Load("ScreenSystemLayer","CreditsInsertCard");
	CREDITS_CARD_ERROR.Load("ScreenSystemLayer","CreditsCardError");
	CREDITS_CARD_TOO_LATE.Load("ScreenSystemLayer","CreditsCardTooLate");
	CREDITS_CARD_NO_NAME.Load("ScreenSystemLayer","CreditsCardNoName");
	CREDITS_CARD_READY.Load("ScreenSystemLayer","CreditsCardReady");
	CREDITS_CARD_CHECKING.Load("ScreenSystemLayer","CreditsCardChecking");
	CREDITS_CARD_REMOVED.Load("ScreenSystemLayer","CreditsCardRemoved");
	CREDITS_FREE_PLAY.Load("ScreenSystemLayer","CreditsFreePlay");
	CREDITS_CREDITS.Load("ScreenSystemLayer","CreditsCredits");
	CREDITS_NOT_PRESENT.Load("ScreenSystemLayer","CreditsNotPresent");
	CREDITS_LOAD_FAILED.Load("ScreenSystemLayer","CreditsLoadFailed");
	CREDITS_LOADED_FROM_LAST_GOOD_APPEND.Load("ScreenSystemLayer","CreditsLoadedFromLastGoodAppend");
	CREDITS_JOIN_ONLY.Load( m_sName, "CreditsJoinOnly" );
}

ScreenSystemLayer::~ScreenSystemLayer()
{
	MESSAGEMAN->Unsubscribe( this, "RefreshCreditText" );
	MESSAGEMAN->Unsubscribe( this, "SystemMessage" );
	MESSAGEMAN->Unsubscribe( this, "SystemMessageNoAnimate" );
}

void ScreenSystemLayer::Init()
{
	Screen::Init();

	this->AddChild(&m_textMessage);
	this->AddChild(&m_textStats);
	this->AddChild(&m_textTime);
	FOREACH_PlayerNumber( p )
		this->AddChild(&m_textCredits[p]);


	/* "Was that a skip?"  This displays a message when an update takes
	 * abnormally long, to quantify skips more precisely, verify them
	 * when they're subtle, and show the time it happened, so you can pinpoint
	 * the time in the log.  Put a dim quad behind it to make it easier to
	 * read. */
	m_LastSkip = 0;
	const float SKIP_LEFT = 320.0f, SKIP_TOP = 60.0f, 
		SKIP_WIDTH = 160.0f, SKIP_Y_DIST = 16.0f;

	m_SkipBackground.StretchTo(RectF(SKIP_LEFT-8, SKIP_TOP-8,
						SKIP_LEFT+SKIP_WIDTH, SKIP_TOP+SKIP_Y_DIST*NUM_SKIPS_TO_SHOW));
	m_SkipBackground.SetDiffuse( RageColor(0,0,0,0.4f) );
	m_SkipBackground.SetHidden( !PREFSMAN->m_bTimestamping );
	this->AddChild(&m_SkipBackground);

	for( int i=0; i<NUM_SKIPS_TO_SHOW; i++ )
	{
		/* This is somewhat big.  Let's put it on the right side, where it'll
		 * obscure the 2P side during gameplay; there's nowhere to put it that
		 * doesn't obscure something, and it's just a diagnostic. */
		m_textSkips[i].LoadFromFont( THEME->GetPathF("Common","normal") );
		m_textSkips[i].SetXY( SKIP_LEFT, SKIP_TOP + SKIP_Y_DIST*i );
		m_textSkips[i].SetHorizAlign( Actor::align_left );
		m_textSkips[i].SetVertAlign( Actor::align_top );
		m_textSkips[i].SetZoom( 0.5f );
		m_textSkips[i].SetDiffuse( RageColor(1,1,1,0) );
		m_textSkips[i].SetShadowLength( 0 );
		this->AddChild(&m_textSkips[i]);
	}

	ReloadCreditsText();
	/* This will be done when we set up the first screen, after GAMESTATE->Reset has
	 * been called. */
	// RefreshCreditsMessages();
}

void ScreenSystemLayer::ReloadCreditsText()
{
	m_textMessage.LoadFromFont( THEME->GetPathF("ScreenSystemLayer","message") );
	m_textMessage.SetName( "Message" );
	SET_XY_AND_ON_COMMAND( m_textMessage ); 

 	m_textStats.LoadFromFont( THEME->GetPathF("ScreenSystemLayer","stats") );
	m_textStats.SetName( "Stats" );
	SET_XY_AND_ON_COMMAND( m_textStats ); 

	m_textTime.LoadFromFont( THEME->GetPathF("ScreenSystemLayer","time") );
	m_textTime.SetName( "Time" );
	m_textTime.SetHidden( !PREFSMAN->m_bTimestamping );
	SET_XY_AND_ON_COMMAND( m_textTime ); 

	FOREACH_PlayerNumber( p )
	{
		m_textCredits[p].LoadFromFont( THEME->GetPathF("ScreenManager","credits") );
		m_textCredits[p].SetName( ssprintf("CreditsP%d",p+1) );
		SET_XY_AND_ON_COMMAND( &m_textCredits[p] );
	}
}

CString ScreenSystemLayer::GetCreditsMessage( PlayerNumber pn ) const
{
	if( CREDITS_JOIN_ONLY && !GAMESTATE->PlayersCanJoin() )
		return "";

	bool bShowCreditsMessage;
	if( GAMESTATE->m_bIsOnSystemMenu )
		bShowCreditsMessage = true;
	else if( MEMCARDMAN->GetCardsLocked() )
		bShowCreditsMessage = !GAMESTATE->IsPlayerEnabled( pn );
	else 
		bShowCreditsMessage = !GAMESTATE->m_bSideIsJoined[pn];
		
	if( !bShowCreditsMessage )
	{
		MemoryCardState mcs = MEMCARDMAN->GetCardState( pn );
		const Profile* pProfile = PROFILEMAN->GetProfile( pn );
		switch( mcs )
		{
		case MEMORY_CARD_STATE_NO_CARD:
			// this is a local machine profile
			if( PROFILEMAN->LastLoadWasFromLastGood(pn) && pProfile )
				return pProfile->GetDisplayName() + CREDITS_LOADED_FROM_LAST_GOOD_APPEND.GetValue();
			else if( PROFILEMAN->LastLoadWasTamperedOrCorrupt(pn) )
				return CREDITS_LOAD_FAILED.GetValue();
			// Prefer the name of the profile over the name of the card.
			else if( pProfile )
				return pProfile->GetDisplayName();
			else if( GAMESTATE->PlayersCanJoin() )
				return CREDITS_INSERT_CARD.GetValue();
			else
				return "";

		case MEMORY_CARD_STATE_WRITE_ERROR: return CREDITS_CARD_ERROR.GetValue();
		case MEMORY_CARD_STATE_TOO_LATE:	return CREDITS_CARD_TOO_LATE.GetValue();
		case MEMORY_CARD_STATE_CHECKING:	return CREDITS_CARD_CHECKING.GetValue();
		case MEMORY_CARD_STATE_REMOVED:		return CREDITS_CARD_REMOVED.GetValue();
		case MEMORY_CARD_STATE_READY:
			if( PROFILEMAN->LastLoadWasFromLastGood(pn) && pProfile )
				return pProfile->GetDisplayName() + CREDITS_LOADED_FROM_LAST_GOOD_APPEND.GetValue();
			else if( PROFILEMAN->LastLoadWasTamperedOrCorrupt(pn) )
				return CREDITS_LOAD_FAILED.GetValue();
			// Prefer the name of the profile over the name of the card.
			else if( pProfile )
				return pProfile->GetDisplayName();
			else if( !MEMCARDMAN->IsNameAvailable(pn) )
				return CREDITS_CARD_READY.GetValue();
			else if( !MEMCARDMAN->GetName(pn).empty() )
				return MEMCARDMAN->GetName(pn);
			else
				return CREDITS_CARD_NO_NAME.GetValue();

		default:
			FAIL_M( ssprintf("%i",mcs) );
		}
	}
	else // bShowCreditsMessage
	{
		switch( GAMESTATE->GetCoinMode() )
		{
		case COIN_HOME:
			if( GAMESTATE->PlayersCanJoin() )
				return CREDITS_PRESS_START.GetValue();
			else
				return CREDITS_NOT_PRESENT.GetValue();

		case COIN_PAY:
		{
			int Credits = GAMESTATE->m_iCoins / PREFSMAN->m_iCoinsPerCredit;
			int Coins = GAMESTATE->m_iCoins % PREFSMAN->m_iCoinsPerCredit;
			CString sCredits = CREDITS_CREDITS;
			if( Credits > 0 || PREFSMAN->m_iCoinsPerCredit == 1 )
				sCredits += ssprintf("  %d", Credits);
			if( PREFSMAN->m_iCoinsPerCredit > 1 )
				sCredits += ssprintf("  %d/%d", Coins, PREFSMAN->m_iCoinsPerCredit );
			return sCredits;
		}
		case COIN_FREE:
			if( GAMESTATE->PlayersCanJoin() )
				return CREDITS_FREE_PLAY.GetValue();
			else
				return CREDITS_NOT_PRESENT.GetValue();

		default:
			ASSERT(0);
		}
	}
}

void ScreenSystemLayer::HandleMessage( const CString &sMessage )
{
	if( sMessage == "RefreshCreditText" )
	{
		// update joined
		FOREACH_PlayerNumber( pn )
			m_textCredits[pn].SetText( GetCreditsMessage(pn) );
	}
	else if( sMessage == "SystemMessage" )
	{
		m_textMessage.SetText( SCREENMAN->GetCurrentSystemMessage() );
		ActorCommands c = ActorCommands( "finishtweening;diffusealpha,1;addx,-640;linear,0.5;addx,+640;sleep,5;linear,0.5;diffusealpha,0" );
		m_textMessage.RunCommands( c );
	}
	else if( sMessage == "SystemMessageNoAnimate" )
	{
		m_textMessage.FinishTweening();
		m_textMessage.SetText( SCREENMAN->GetCurrentSystemMessage() );
		m_textMessage.SetX( 4 );
		m_textMessage.SetDiffuseAlpha( 1 );
		m_textMessage.BeginTweening( 5 );
		m_textMessage.BeginTweening( 0.5f );
		m_textMessage.SetDiffuse( RageColor(1,1,1,0) );
	}
	Screen::HandleMessage( sMessage );
}

void ScreenSystemLayer::AddTimestampLine( const CString &txt, const RageColor &color )
{
	m_textSkips[m_LastSkip].SetText( txt );
	m_textSkips[m_LastSkip].StopTweening();
	m_textSkips[m_LastSkip].SetDiffuse( RageColor(1,1,1,1) );
	m_textSkips[m_LastSkip].BeginTweening( 0.2f );
	m_textSkips[m_LastSkip].SetDiffuse( color );
	m_textSkips[m_LastSkip].BeginTweening( 3.0f );
	m_textSkips[m_LastSkip].BeginTweening( 0.2f );
	m_textSkips[m_LastSkip].SetDiffuse( RageColor(1,1,1,0) );

	m_LastSkip++;
	m_LastSkip %= NUM_SKIPS_TO_SHOW;
}

void ScreenSystemLayer::UpdateSkips()
{
	if( !PREFSMAN->m_bTimestamping && !PREFSMAN->m_bLogSkips )
		return;

	/* Use our own timer, so we ignore `/tab. */
	const float UpdateTime = SkipTimer.GetDeltaTime();

	/* FPS is 0 for a little while after we load a screen; don't report
	 * during this time. Do clear the timer, though, so we don't report
	 * a big "skip" after this period passes. */
	if( !DISPLAY->GetFPS() )
		return;

	/* We want to display skips.  We expect to get updates of about 1.0/FPS ms. */
	const float ExpectedUpdate = 1.0f / DISPLAY->GetFPS();
	
	/* These are thresholds for severity of skips.  The smallest
	 * is slightly above expected, to tolerate normal jitter. */
	const float Thresholds[] =
	{
		ExpectedUpdate * 2.0f, ExpectedUpdate * 4.0f, 0.1f, -1
	};

	int skip = 0;
	while( Thresholds[skip] != -1 && UpdateTime > Thresholds[skip] )
		skip++;

	if( skip )
	{
		CString time(SecondsToMMSSMsMs(RageTimer::GetTimeSinceStart()));

		static const RageColor colors[] =
		{
			RageColor(0,0,0,0),		  /* unused */
			RageColor(0.2f,0.2f,1,1), /* light blue */
			RageColor(1,1,0,1),		  /* yellow */
			RageColor(1,0.2f,0.2f,1)  /* light red */
		};

		if( PREFSMAN->m_bTimestamping )
			AddTimestampLine( ssprintf("%s: %.0fms (%.0f)", time.c_str(), 1000*UpdateTime, UpdateTime/ExpectedUpdate), colors[skip] );
		if( PREFSMAN->m_bLogSkips )
			LOG->Trace( "Frame skip: %.0fms (%.0f)", 1000*UpdateTime, UpdateTime/ExpectedUpdate );
	}
}

void ScreenSystemLayer::Update( float fDeltaTime )
{
	Screen::Update(fDeltaTime);

	if( PREFSMAN  &&  (bool)PREFSMAN->m_bShowStats )
	{
		m_textStats.SetDiffuse( RageColor(1,1,1,0.7f) );
		m_textStats.SetText( DISPLAY->GetStats() );
	}
	else
	{
		m_textStats.SetDiffuse( RageColor(1,1,1,0) ); /* hide */
	}

	UpdateSkips();

	if( PREFSMAN->m_bTimestamping )
		m_textTime.SetText( SecondsToMMSSMsMs(RageTimer::GetTimeSinceStart()) );
}

/*
 * (c) 2001-2005 Chris Danford, Glenn Maynard
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
