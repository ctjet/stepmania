#include <Arduino.h>
#include <FastLED.h>

#define NUM_LEDS_STRIP 100
#define NUM_LEDS NUM_LEDS_STRIP

#define DATA_PIN 6

CRGB leds[NUM_LEDS];
uint8_t gHue = 0;

int incomingByte = 0;
uint8_t serialBuff[100];
int serialBuffLoc = 0;

bool justFlushed = false;

// # LIGHT_MARQUEE_UP_LEFT
// # LIGHT_MARQUEE_UP_RIGHT
// # LIGHT_MARQUEE_LR_LEFT
// # LIGHT_MARQUEE_LR_RIGHT
// # LIGHT_BASS_LEFT
// # LIGHT_BASS_RIGHT
int ledZoneMapping[6] = {1, 3, 4, 2, 0, 5}; //input led, output which zone
int ledZoneStart[6] = {0, 10, 30, 50, 70, 90};
int ledZoneLength[6] = {10, 20, 20, 20, 20, 10};

bool lights[6];
bool prevLights[6];
bool lightsActivatedThisFrame[6];
int lightsInitColor[6];

// int bassColor = 0;
// bool prevBass = false;

const int ledR = 9;
const int ledG = 10;
const int ledB = 11;

void setup()
{
  Serial.begin(115200);                                    // opens serial port, sets data rate to 9600 bps
  pinMode(ledR, OUTPUT);                                   // sets the pin as output
  pinMode(ledG, OUTPUT);                                   // sets the pin as output
  pinMode(ledB, OUTPUT);                                   // sets the pin as output
  FastLED.addLeds<WS2812B, DATA_PIN, BRG>(leds, NUM_LEDS); // GRB ordering is typical
}

uint8_t printableSextetToPlain(uint8_t printable)
{
  return printable & 0x3F;
}

void sextetToBools(uint8_t sextet)
{
  for (int i = 0; i < 6; i++)
  {
    lights[i] = (sextet & (1 << i)) > 0;
  }
}

void serialFlush(){
  while(Serial.available() > 0) {
    char t = Serial.read();
  }
  Serial.flush();
}

void writeToLed(uint8_t r, uint8_t g, uint8_t b)
{
  analogWrite(ledR, r);
  analogWrite(ledG, g);
  analogWrite(ledB, b);
}


void writeToLedHsv(uint8_t hsv)
{
  CHSV hsvTmp(hsv, 255, 255);
  CRGB rgb;
  hsv2rgb_rainbow(hsvTmp, rgb);
  writeToLed(rgb.r, rgb.g, rgb.b);
}

void loop()
{

  EVERY_N_MILLISECONDS(20) { gHue++; } // slowly cycle the "base color" through the rainbow
  EVERY_N_SECONDS(1) { Serial.println("alive"); }

  if (Serial.available() > 0)
  {
    incomingByte = Serial.read(); // read the incoming byte:
    serialBuff[serialBuffLoc++] = incomingByte;
    if (incomingByte == '\n')
    {
      serialBuff[serialBuffLoc] = 0;
      serialBuffLoc = 0;

      uint8_t sextet = printableSextetToPlain(serialBuff[0]);
      sextetToBools(sextet);
      for (int i = 0; i < 6; i++)
      {
        lightsActivatedThisFrame[i] = false;
        if (!prevLights[i] && lights[i])
        {
          lightsInitColor[i] = gHue;
          lightsActivatedThisFrame[i] = true;
        }
        prevLights[i] = lights[i];
      }
    }
  }

  bool allActive = true;
  
  //flush connection each song to hopefully get rid of lag spikes after a while
  for(int i = 0; i<6; i++){
    if(!lights[i]){
      allActive = false;
      break;
    }
  }
  if (allActive){
    if(!justFlushed){
      serialFlush();
      justFlushed = true;
    }
  }else{
    justFlushed = false;
  }


  uint8_t basshsv = 224 + lights[5] ? lightsInitColor[5] : 0 + lights[4] ? 128 + lightsInitColor[4]
                                                                         : 0;

  EVERY_N_MILLISECONDS(20){
    fadeToBlackBy(leds,NUM_LEDS_STRIP,60);
  }                                        
  for (int i = 0; i < 6; i++)
  {
    CRGB color = CRGB(0, 0, 0);
    int zone = ledZoneMapping[i];
    int start = ledZoneStart[zone];
    int length = ledZoneLength[zone];
    if (lights[i])
    {
      uint8_t localColor = lightsInitColor[i];
      switch (zone)
      {
      case 1:
        color = CHSV(localColor, 255, 255);
        break;
      case 2:
        color = CHSV(localColor + 160, 255, 255);
        break;
      case 3:
        color = CHSV(localColor + 64, 255, 255);
        break;
      case 4:
        color = CHSV(localColor+96, 255, 255);
        break;
      default:
        color = CHSV(basshsv, 255, 255);
        break;
      }
      fill_solid(leds + start, length, color);
    }
  }
  int activated = 0;
  for (int i = 0; i < 4; i++){
    if (lightsActivatedThisFrame[i]) {
      activated ++;
    }
  }
  if (activated == 2) {
    CHSV blendColor;
    bool color1Found = false;
    int zone1;
    int zone2;
    CHSV color1;
    CHSV color2;
    for (int i = 0; i < 4; i++)
    {
      if (lightsActivatedThisFrame[i]){
        int zone = ledZoneMapping[i];
        uint8_t localColor = lightsInitColor[i];
        CHSV color;
        switch (zone)
        {
        case 1:
          color = CHSV(localColor, 255, 255);
          break;
        case 2:
          color = CHSV(localColor + 160, 255, 255);
          break;
        case 3:
          color = CHSV(localColor + 64, 255, 255);
          break;
        case 4:
          color = CHSV(localColor+96, 255, 255);
          break;
        default:
          color = CHSV(basshsv, 255, 255);
          break;
        }
        if (!color1Found ){
          color1Found = true;
          color1 = color;
          zone1=zone;
        }
        else{
          color2=color;
          zone2=zone;
        }
      }
    }
    blendColor = blend(color1,color2,128);
    // int start = ledZoneStart[zone1];
    // int length = ledZoneLength[zone1];
    // fill_solid(leds + start, length, blendColor);
    // start = ledZoneStart[zone2];
    // length = ledZoneLength[zone2];
    fill_solid(leds, NUM_LEDS, blendColor);
  }

  FastLED.show();

  if (lights[4] || lights[5])
  {

    writeToLed(leds[0].r,leds[0].g, leds[0].b);
  }
  else
  {
    writeToLed(0, 0, 0);
  }
}