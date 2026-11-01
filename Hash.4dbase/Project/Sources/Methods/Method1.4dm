//%attributes = {}
PID:=Progress New
Progress SET PROGRESS(PID; -1)
Progress SET BUTTON ENABLED(PID; True:C214)

$path:=System folder:C487(Desktop:K41:16)+"openssl-OpenSSL_1_1_0-stable.zip"

$callbackMethod:="PROGRESS"

$hash:=Generate checksum($path; Checksum MD5; Checksum Format Base64; $callbackMethod)

Progress QUIT(PID)

If ($hash#"")
	
	ALERT:C41($hash)
	
Else 
	
	ALERT:C41("Aborted!")
	
End if 