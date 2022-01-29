import serial
from graphics import *

serialPort = serial.Serial(port = "COM2", baudrate=115200,
                           bytesize=8, timeout=2, stopbits=serial.STOPBITS_ONE)


serialString = ""                           # Used to hold data coming over UART

win = GraphWin("Stepmania", 600, 100)
win.setBackground("white")

def printableSextetToPlain(printable):
    return printable & 0x3F

# in order
# LIGHT_MARQUEE_UP_LEFT
# LIGHT_MARQUEE_UP_RIGHT
# LIGHT_MARQUEE_LR_LEFT
# LIGHT_MARQUEE_LR_RIGHT
# LIGHT_BASS_LEFT
# LIGHT_BASS_RIGHT
def sextetToBools(sextet):
    return ((sextet & 0x01) > 0, (sextet & 0x02) > 0, (sextet & 0x04) > 0, (sextet & 0x08) > 0, (sextet & 0x1) > 0, (sextet & 0x20) > 0)

def draw(sextetBools):
    for i in range(0,6):
        r = Rectangle(Point(0+i*100,0), Point(100+i*100,100))
        if(sextetBools[i]):
          r.setFill("red")
        else:
          r.setFill("white")
        r.draw(win)



while(1):

    # Wait until there is data waiting in the serial buffer
    if(serialPort.in_waiting > 0):

        readChar = serialPort.read().decode('Ascii')
        # Read data out of the buffer until a carraige return / new line is found
        serialString += readChar

        if readChar == '\n': 
            if len(serialString) > 0:
                firstChar = serialString[0]
                printableSextet = ord(firstChar)
                sextet = printableSextetToPlain(printableSextet)


                # Print the contents of the serial data
                # print(serialString, end='')
                print (format(sextet,'08b'))
                draw(sextetToBools(sextet))

                # Tell the device connected over the serial port that we recevied the data!
                # The b at the beginning is used to indicate bytes!
                # serialPort.write(b"Thank you for sending data \r\n")
            serialString = ''
        

win.close()