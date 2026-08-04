{ ================================================================== }
{ UNETPAS.INC - Turbo Pascal (DSS TPC) binding for the UNET network   }
{ DLL. A thin wrapper over the SDK's LIBMAN.INC: it adds the UNET      }
{ function numbers, error codes and typed call wrappers.              }
{                                                                     }
{ Include order (LIBMAN.INC and the DSS cores must come first). Use   }
{ the standard include directive for each, in this sequence:          }
{   DSSCORE.INC, DSSFILE.INC, DSSSYS.INC, LIBMAN.INC, then this file. }
{ (Do not put an include directive inside a comment - TP comments do  }
{ not nest, so the directive's closing brace would end the comment.)  }
{                                                                     }
{ WINDOW RULE: build the host with  TPC /D:8000 ...  so its code,     }
{ globals and stack stay below 0x8000 (window 1). Then load the DLL   }
{ into window 2:  UNetLoad('UNETESP.DLL', 2). The DLL must NEVER go    }
{ into window 3 (the ESP UART is mapped there during calls).          }
{                                                                     }
{ Bring the network up first with NETUP (Wi-Fi) or NETCFG -i / IFUP   }
{ (RTL). The full contract is in docs/UNETAPI.md.                     }
{ ================================================================== }

const
  { function numbers }
  UNetFnGetCaps  = 2;
  UNetFnNetInit  = 3;
  UNetFnNetDone  = 4;
  UNetFnConnect  = 5;
  UNetFnSend     = 6;
  UNetFnRecv     = 7;
  UNetFnClose    = 8;
  UNetFnStatus   = 9;
  UNetFnUdpOpen  = 10;
  UNetFnResolve  = 11;
  UNetFnPing     = 12;
  UNetFnRxPause  = 13;
  UNetFnRxResume = 14;
  UNetFnGetInfo  = 15;
  UNetFnLastErr  = 16;
  UNetFnSetOpt   = 17;

  { error codes (UNetErr / function results) }
  NErrOk          = 0;
  NErrHw          = 1;
  NErrNoNet       = 2;
  NErrDns         = 3;
  NErrConnect     = 4;
  NErrSend        = 5;
  NErrRecvTimeout = 6;
  NErrClosed      = 7;
  NErrCancel      = 8;
  NErrParam       = 9;
  NErrNotSup      = 10;
  NErrState       = 11;
  NErrTimeout     = 12;
  NErrBusy        = 13;
  NErrProto       = 14;
  NErrAgain       = 15;                  { send suspended (UNetOptSendSlice):
                                           repeat the same UNetSendCh call }

  { capability bits (UNetCaps) }
  UNetCapTcp         = $0001;
  UNetCapUdp         = $0002;
  UNetCapResolve     = $0004;
  UNetCapPing        = $0008;
  UNetCapMultichan   = $0010;
  UNetCapListen      = $0020;
  UNetCapRawEth      = $0040;
  UNetCapTransparent = $0080;
  UNetCapRxFlow      = $0100;
  UNetCapAsyncSend   = $0200;            { NErrAgain / UNetOptSendSlice support }

  { GETINFO fields }
  UNetIfBackend = 0;
  UNetIfIp      = 1;
  UNetIfMask    = 2;
  UNetIfGw      = 3;
  UNetIfMac     = 4;
  UNetIfDns1    = 5;
  UNetIfDns2    = 6;
  UNetIfIpSrc   = 7;
  UNetIfSsid    = 8;
  UNetIfBaud    = 9;
  UNetIfNtp     = 10;
  UNetIfTz      = 11;
  UNetIfHw      = 12;

  { SETOPT options }
  UNetOptCancelKeys = 1;
  UNetOptRxTrig     = 2;
  UNetOptSendSlice  = 3;                 { ms of silence before SEND suspends
                                           with NErrAgain; 0 = blocking. Gate
                                           on UNetCapAsyncSend. }

  { STATUS(channel) state bits (UNetStatusCh) }
  UNetStConn   = $0002;                  { channel is connected }
  UNetStRxPend = $0004;                  { data buffered for this channel;
                                           only backends with
                                           UNetCapMultichan report it }

  { RECV flag bits (UNetRecvFlags after UNetRecv / UNetRecvCh) }
  UNetRxfTrunc = $0001;                  { datagram truncated (never on ESP) }
  UNetRxfMore  = $0002;                  { more data for this channel }
  UNetRxfLost  = $0004;                  { overrun or dropped frame }
  UNetRxfXChan = $0008;                  { data pending on the OTHER channel:
                                           an empty read means "switch
                                           channels", not "link idle" }

const
  UNetMaxArg = 81;                       { longest host/port argument we stage }

type
  UNetBuf = array[0..81] of char;        { ASCIIZ scratch (named for var params) }

var
  UNetHandle : integer;                  { handle of the loaded DLL }
  UNetErr    : byte;                     { last function status (NErr*) }
  UNetRecvFlags : integer;               { RECV flag bits (UNetRxf*) }
  UNetBufA   : UNetBuf;                  { ASCIIZ scratch, DE-side }
  UNetBufB   : UNetBuf;                  { ASCIIZ scratch, IX-side }
  UNetBufC   : UNetBuf;                  { ASCIIZ scratch, IY-side }
  UNetOut    : UNetBuf;                  { ASCIIZ output buffer }

{ Copy a Pascal string to an ASCIIZ buffer. The buffer holds UNetMaxArg
  chars + NUL; callers must reject longer strings first (UNetArgOk). }
procedure UNetZ(s : DssStr; var dst : UNetBuf);
var i, n : integer;
begin
  n := length(s);
  if n > UNetMaxArg then n := UNetMaxArg;
  for i := 1 to n do dst[i - 1] := s[i];
  dst[n] := chr(0)
end;

{ True if s fits a staging buffer; otherwise latches NErrParam in UNetErr. }
function UNetArgOk(var s : DssStr) : boolean;
begin
  UNetArgOk := true;
  if length(s) > UNetMaxArg then
  begin
    UNetErr := NErrParam;
    UNetArgOk := false
  end
end;

{ Convert an ASCIIZ output buffer back to a Pascal string. }
function UNetFromZ(var src : UNetBuf) : DssStr;
var s : DssStr; i : integer;
begin
  s := '';
  i := 0;
  while (i <= 81) and (src[i] <> chr(0)) do
  begin s := s + src[i]; i := i + 1 end;
  UNetFromZ := s
end;

{ Call DLL function `func`; the status (register A) is stored in UNetErr.
  Every UNET function returns its status in A, so the LibCall boolean is
  not needed. A procedure (not a function) so callers can invoke it as a
  statement - TP does not allow discarding a function result. }
procedure UNetCall(func : integer);
begin
  if LibCall(UNetHandle, func) then ;
  UNetErr := LibRegA
end;

{ Load a UNET DLL into window 1 or 2. Returns true on success.
  NOTE: `name` is resolved against the DSS current directory (libman/DSS do
  not search PATH or the program's own directory). Run the program from the
  directory that holds the DLL, or pass a full path such as
  'C:\WIFI\UNETESP.DLL'. }
function UNetLoad(name : DssStr; win : integer) : boolean;
begin
  UNetLoad := false;
  UNetHandle := LibLoad(name, win);
  if UNetHandle < 0 then begin UNetErr := NErrHw; exit end;
  UNetLoad := true
end;

procedure UNetUnload;
begin
  if UNetHandle >= 0 then
    if LibFree(UNetHandle) then ;
  UNetHandle := -1
end;

function UNetCaps : integer;
begin
  UNetCall(UNetFnGetCaps);
  UNetCaps := LibRegDE.W
end;

function UNetInit : byte;
begin
  UNetCall(UNetFnNetInit);
  UNetInit := UNetErr
end;

function UNetDone : byte;
begin
  UNetCall(UNetFnNetDone);
  UNetDone := UNetErr
end;

{ Channel-aware entry points. Channel 0 behaves exactly like the plain
  functions, which simply call these with ch = 0; channel 1 requires a backend
  whose UNetCaps has UNetCapMultichan (otherwise NErrParam). Two channels let
  one program hold an FTP control and data connection at the same time. Read
  them in turn: a read returning 0 with UNetRxfXChan set in UNetRecvFlags means
  the other channel has data waiting. }
function UNetCloseCh(ch : integer) : byte;
begin
  LibRegA := ch;
  UNetCall(UNetFnClose);
  UNetCloseCh := UNetErr
end;

function UNetClose : byte;
begin UNetClose := UNetCloseCh(0) end;

function UNetConnectCh(ch : integer; host, port : DssStr) : byte;
begin
  UNetConnectCh := NErrParam;
  if not UNetArgOk(host) then exit;
  if not UNetArgOk(port) then exit;
  UNetZ(host, UNetBufA);
  UNetZ(port, UNetBufB);
  LibRegA := ch;
  LibRegDE.W := addr(UNetBufA);
  LibRegIX.W := addr(UNetBufB);
  UNetCall(UNetFnConnect);
  UNetConnectCh := UNetErr
end;

function UNetConnect(host, port : DssStr) : byte;
begin UNetConnect := UNetConnectCh(0, host, port) end;

function UNetUdpOpenCh(ch : integer; host, rport, lport : DssStr) : byte;
begin
  UNetUdpOpenCh := NErrParam;
  if not UNetArgOk(host) then exit;
  if not UNetArgOk(rport) then exit;
  if not UNetArgOk(lport) then exit;
  UNetZ(host, UNetBufA);
  UNetZ(rport, UNetBufB);
  LibRegA := ch;
  LibRegDE.W := addr(UNetBufA);
  LibRegIX.W := addr(UNetBufB);
  if length(lport) = 0 then
    LibRegIY.W := 0
  else
  begin
    UNetZ(lport, UNetBufC);
    LibRegIY.W := addr(UNetBufC)
  end;
  UNetCall(UNetFnUdpOpen);
  UNetUdpOpenCh := UNetErr
end;

function UNetUdpOpen(host, rport, lport : DssStr) : byte;
begin UNetUdpOpen := UNetUdpOpenCh(0, host, rport, lport) end;

{ Per-channel state (UNetSt* bits) in state. Returns NErrOk or a NErr* code. }
function UNetStatusCh(ch : integer; var state : integer) : byte;
begin
  LibRegA := ch;
  UNetCall(UNetFnStatus);
  state := LibRegDE.W;
  UNetStatusCh := UNetErr
end;

{ Send a string's bytes straight from the string body - no staging copy, so
  the full 255-char DssStr is allowed (SEND takes pointer+length, no NUL
  needed). Returns bytes sent (>=0) or -(NErr*) on failure. }
function UNetSendCh(ch : integer; s : DssStr) : integer;
begin
  LibRegA := ch;
  LibRegDE.W := addr(s) + 1;             { skip the length byte }
  LibRegIX.W := length(s);
  UNetCall(UNetFnSend);
  if UNetErr = NErrOk then
    UNetSendCh := LibRegDE.W
  else
    UNetSendCh := -UNetErr
end;

function UNetSend(s : DssStr) : integer;
begin UNetSend := UNetSendCh(0, s) end;

{ Receive into UNetOut (up to 80 bytes). Returns byte count (>0), 0 on idle,
  or -(NErr*) (e.g. -NErrClosed) on close/error. Read the text with
  UNetRecvStr; the RECV flag bits are left in UNetRecvFlags. }
function UNetRecvCh(ch : integer; timeout : integer) : integer;
begin
  LibRegA := ch;
  LibRegDE.W := addr(UNetOut);
  LibRegIX.W := 80;
  LibRegIY.W := timeout;
  UNetCall(UNetFnRecv);
  UNetRecvFlags := LibRegIX.W;
  if UNetErr = NErrOk then
  begin
    UNetOut[LibRegDE.W] := chr(0);       { terminate for UNetRecvStr }
    UNetRecvCh := LibRegDE.W
  end
  else
    UNetRecvCh := -UNetErr
end;

function UNetRecv(timeout : integer) : integer;
begin UNetRecv := UNetRecvCh(0, timeout) end;

function UNetRecvStr : DssStr;
begin UNetRecvStr := UNetFromZ(UNetOut) end;

{ Resolve a host to a dotted quad. Returns NErrOk or a NErr* code. }
function UNetResolve(host : DssStr; var dst : DssStr) : byte;
begin
  UNetResolve := NErrParam;
  dst := '';
  if not UNetArgOk(host) then exit;
  UNetZ(host, UNetBufA);
  LibRegDE.W := addr(UNetBufA);
  LibRegIX.W := addr(UNetOut);
  UNetCall(UNetFnResolve);
  dst := UNetFromZ(UNetOut);
  UNetResolve := UNetErr
end;

{ Ping a host. Returns round-trip ms (>=0) or -(NErr*). }
function UNetPing(host : DssStr; timeout : integer) : integer;
begin
  UNetPing := -NErrParam;
  if not UNetArgOk(host) then exit;
  UNetZ(host, UNetBufA);
  LibRegDE.W := addr(UNetBufA);
  LibRegIY.W := timeout;
  UNetCall(UNetFnPing);
  if UNetErr = NErrOk then
    UNetPing := LibRegDE.W
  else
    UNetPing := -UNetErr
end;

procedure UNetRxPause;
begin UNetCall(UNetFnRxPause) end;

procedure UNetRxResume;
begin UNetCall(UNetFnRxResume) end;

{ Copy a network info field into a Pascal string. }
function UNetGetInfo(field : integer) : DssStr;
begin
  LibRegA := field;
  LibRegDE.W := addr(UNetOut);
  LibRegIX.W := 80;
  UNetCall(UNetFnGetInfo);
  UNetGetInfo := UNetFromZ(UNetOut)
end;

function UNetLastErr : DssStr;
begin
  LibRegDE.W := addr(UNetOut);
  LibRegIX.W := 80;
  UNetCall(UNetFnLastErr);
  UNetLastErr := UNetFromZ(UNetOut)
end;

function UNetSetOpt(opt, val : integer) : byte;
begin
  LibRegA := opt;
  LibRegDE.W := val;
  UNetCall(UNetFnSetOpt);
  UNetSetOpt := UNetErr
end;

{ Network status without touching hardware. Returns NErrOk (configured) or
  NErrNoNet; bits: 1 = env set, 2 = NETINIT done. }
function UNetNetStatus(var bits : integer) : byte;
begin
  LibRegA := $FF;
  UNetCall(UNetFnStatus);
  bits := LibRegDE.W;
  UNetNetStatus := UNetErr
end;
