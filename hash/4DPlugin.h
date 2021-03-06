/* --------------------------------------------------------------------------------
 #
 #	4DPlugin.h
 #	source generated by 4D Plugin Wizard
 #	Project : Hash
 #	author : miyako
 #	2016/10/21
 #
 # --------------------------------------------------------------------------------*/



// --- Hash
void Generate_checksum(sLONG_PTR *pResult, PackagePtr pParams);

#define Checksum_MD5 0
#define Checksum_SHA1 1
#define Checksum_SHA256 2
#define Checksum_SHA384 3
#define Checksum_SHA512 5

#define Checksum_Format_Hex 0
#define Checksum_Format_Base64 1

typedef unsigned int method_id_t;

#define BUFFER_SIZE 8192