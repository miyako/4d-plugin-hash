//%attributes = {}
C_REAL:C285($1; $POS)
C_REAL:C285($2; $LEN)
C_BOOLEAN:C305($0)

$POS:=$1
$LEN:=$2

$progress:=$POS/$LEN
$message:=String:C10($POS)+"/"+String:C10($LEN)+" bytes"

Progress SET PROGRESS(PID; $progress; $message)

DELAY PROCESS:C323(Current process:C322; 5)

$0:=Progress Stopped(PID)
