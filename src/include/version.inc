; ======================================================
; Sprinter ESP Network Kit package version.
; Keep this as the single source for banner version text.
; ======================================================

	IFNDEF	_VERSION_INC
	DEFINE	_VERSION_INC

PACKAGE_VERSION_MAJOR	EQU 0
PACKAGE_VERSION_MINOR	EQU 3
PACKAGE_VERSION_PATCH	EQU 0

	; Emit "v.<major>.<minor>.<patch>" built from the constants above. Placed
	; right after the tool name in each banner, e.g. "FTP v.0.2.1 - ...".
	; Assumes single-digit components (the +'0' turns each into its ASCII digit);
	; revisit if a component reaches 10.
	; No surrounding spaces or trailing 0 - the banner supplies those.
	MACRO	PACKAGE_VERSION_TAG
	DB "v.", PACKAGE_VERSION_MAJOR+'0', ".", PACKAGE_VERSION_MINOR+'0', ".", PACKAGE_VERSION_PATCH+'0'
	ENDM

	ENDIF
