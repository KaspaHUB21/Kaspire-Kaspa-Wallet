param([Parameter(Mandatory=$true)][string]$Exe,
      [Parameter(Mandatory=$true)][string]$DiagnosticRoot)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This disposable-wallet UI check is for isolated CI runners only.' }
if (Test-Path (Join-Path $env:LOCALAPPDATA 'Kaspire\wallets.dpapi')) {
    throw 'Refusing UI test: an existing Windows wallet catalogue is present.'
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName Accessibility
Add-Type -ReferencedAssemblies ([Accessibility.IAccessible].Assembly.Location), 'System.dll' @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class KaspireUi {
  public delegate bool EnumProc(IntPtr window, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr window, EnumProc callback, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, string text);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] static extern IntPtr ReadControl(IntPtr window, uint message, IntPtr wparam, StringBuilder text);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int mode);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window, out Rect rect);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window, ref Point point);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
  [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr window, uint objectId, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out Accessibility.IAccessible accessible);
  [DllImport("oleacc.dll")] static extern int AccessibleChildren(Accessibility.IAccessible accessible, int start, int count, [Out, MarshalAs(UnmanagedType.LPArray,SizeParamIndex=2)] object[] children, out int obtained);
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
  public static void PublicNavigation(IntPtr root, string label) {
    // CI starts with the default Midnight theme, 100% app text scale and an
    // empty wallet. These anchors follow the exact checked dashboard layout,
    // including its DPI scale. NEVER use coordinates for signing approval.
    Rect client;GetClientRect(root,out client);Point origin=new Point();ClientToScreen(root,ref origin);
    double scale=GetDpiForWindow(root)/96.0, width=(client.Right-client.Left)/scale;
    if(width<900)throw new InvalidOperationException("CI window is too narrow for dashboard anchors");
    double left=(width-64)*5/11, column=(left-16)/3, x,y;
    if(label=="Wallet overview"){x=width-40;y=40;}
    else {
      int col,row=0;
      if(label=="Send")col=0;else if(label=="Receive")col=1;else if(label=="Settings"){col=2;row=1;}
      else if(label=="Assets"){col=0;row=2;}else if(label=="Activity"){col=1;row=2;}else if(label=="UTXOs"){col=2;row=2;}
      else throw new InvalidOperationException("Coordinate action is not an approved PUBLIC navigation action");
      x=20+column/2+col*(column+8);y=357+row*84;
    }
    SetCursorPos(origin.X+(int)Math.Round(x*scale),origin.Y+(int)Math.Round(y*scale));
    mouse_event(0x0002,0,0,0,UIntPtr.Zero);mouse_event(0x0004,0,0,0,UIntPtr.Zero);
  }
  public static string Class(IntPtr window) { var text=new StringBuilder(256); GetClassName(window,text,text.Capacity); return text.ToString(); }
  public static string Text(IntPtr window) { var text=new StringBuilder(16384); if(string.Equals(Class(window),"Edit",StringComparison.OrdinalIgnoreCase))ReadControl(window,0x000D,new IntPtr(text.Capacity),text);else GetWindowText(window,text,text.Capacity); return text.ToString(); }
  public static IntPtr Input(IntPtr root, string title) {
    IntPtr container=IntPtr.Zero, edit=IntPtr.Zero;
    EnumChildWindows(root,(window,data)=> { if(Class(window)=="KaspireEmbeddedSecureInput" && Text(window)==title)container=window; return true; },IntPtr.Zero);
    if(container!=IntPtr.Zero)EnumChildWindows(container,(window,data)=> {if(string.Equals(Class(window),"Edit",StringComparison.OrdinalIgnoreCase))edit=window;return true;},IntPtr.Zero);
    return edit;
  }
  public static bool OldPopup(IntPtr root) {
    bool found=false;EnumChildWindows(root,(window,data)=> { if(Class(window)=="KaspireNativeSecurityDialog")found=true;return true; },IntPtr.Zero); return found;
  }
  static bool PressNode(Accessibility.IAccessible node, object child, string label, int depth) {
    if (depth>64) return false;
    try {
      // MSAA may return numeric child IDs for containers, not only leaves.
      if(!Equals(child,0)) {
        try { var nested=node.get_accChild(child) as Accessibility.IAccessible;
          if(nested!=null)return PressNode(nested,0,label,depth+1);
        }catch(COMException){}
      }
      string name=null;try{name=node.get_accName(child);}catch(COMException){}
      if (string.Equals((name??"").Trim(),label,StringComparison.OrdinalIgnoreCase)) {
        int left,top,width,height;node.accLocation(out left,out top,out width,out height,child);
        if(width<=0||height<=0)throw new InvalidOperationException("Button is clipped");
        string action=null;try{action=node.get_accDefaultAction(child);}catch(COMException){}
        if(Convert.ToInt32(node.get_accRole(child))==43 || !string.IsNullOrEmpty(action)) {
          node.accDoDefaultAction(child);return true;
        }
        // The Windows MSAA provider reports custom InkWell/IconButton labels
        // as text rather than push buttons. Exercise a real pointer click for
        // these four PUBLIC navigation actions only, never security approval.
        if(string.Equals(label,"Send",StringComparison.OrdinalIgnoreCase) ||
           string.Equals(label,"Receive",StringComparison.OrdinalIgnoreCase) ||
           string.Equals(label,"Settings",StringComparison.OrdinalIgnoreCase) ||
           string.Equals(label,"Show password",StringComparison.OrdinalIgnoreCase) ||
           string.Equals(label,"Hide password",StringComparison.OrdinalIgnoreCase) ||
           string.Equals(label,"Wallet overview",StringComparison.OrdinalIgnoreCase)) {
          SetCursorPos(left+width/2,top+height/2);
          mouse_event(0x0002,0,0,0,UIntPtr.Zero);mouse_event(0x0004,0,0,0,UIntPtr.Zero);return true;
        }
      }
      if(!Equals(child,0))return false;
      int count=Math.Min(node.accChildCount,1000), obtained=0;
      object[] children=new object[count];AccessibleChildren(node,0,count,children,out obtained);
      for(int i=0;i<obtained;i++) {
        var nested=children[i] as Accessibility.IAccessible;
        if(nested!=null && PressNode(nested,0,label,depth+1))return true;
        if(nested==null && children[i]!=null && PressNode(node,children[i],label,depth+1))return true;
      }
    }catch(COMException){}return false;
  }
  public static bool Press(IntPtr root, string label) {
    var windows=new List<IntPtr>();windows.Add(root);
    EnumChildWindows(root,(window,data)=>{if(Class(window).StartsWith("FLUTTER",StringComparison.OrdinalIgnoreCase))windows.Add(window);return true;},IntPtr.Zero);
    foreach(var window in windows) {
      Guid iid=new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");Accessibility.IAccessible accessible;
      if(AccessibleObjectFromWindow(window,0xFFFFFFFC,ref iid,out accessible)==0 && accessible!=null && PressNode(accessible,0,label,0))return true;
    }return false;
  }
  static void CollectButtons(Accessibility.IAccessible node, object child, int depth, List<string> labels) {
    if(depth>64)return;
    try {
      if(!Equals(child,0)) {
        try { var nested=node.get_accChild(child) as Accessibility.IAccessible;
          if(nested!=null){CollectButtons(nested,0,depth+1,labels);return;}
        }catch(COMException){}
      }
      // Called only after closing every native secret field, on a disposable
      // empty wallet's public dashboard. Record public labels, not input text.
      string name=null;try{name=node.get_accName(child);}catch(COMException){}
      if(!string.IsNullOrEmpty(name))labels.Add(Convert.ToInt32(node.get_accRole(child))+": "+name);
      if(!Equals(child,0))return;
      int count=Math.Min(node.accChildCount,1000), obtained=0;
      object[] children=new object[count];AccessibleChildren(node,0,count,children,out obtained);
      for(int i=0;i<obtained;i++) {
        var nested=children[i] as Accessibility.IAccessible;
        if(nested!=null)CollectButtons(nested,0,depth+1,labels);
        else if(children[i]!=null)CollectButtons(node,children[i],depth+1,labels);
      }
    }catch(COMException){}
  }
  public static string[] Buttons(IntPtr root) {
    var labels=new List<string>();
    EnumChildWindows(root,(window,data)=> {
      if(Class(window).StartsWith("FLUTTER",StringComparison.OrdinalIgnoreCase)) {
        Guid iid=new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");Accessibility.IAccessible accessible;
        if(AccessibleObjectFromWindow(window,0xFFFFFFFC,ref iid,out accessible)==0 && accessible!=null)CollectButtons(accessible,0,0,labels);
      }return true;
    },IntPtr.Zero);
    return labels.ToArray();
  }
}
'@
$Process = Start-Process $Exe -WorkingDirectory (Split-Path $Exe -Parent) -PassThru -RedirectStandardOutput (Join-Path $DiagnosticRoot 'dialog-out.log') -RedirectStandardError (Join-Path $DiagnosticRoot 'dialog-error.log')
try {
    Start-Sleep -Seconds 6
    $Process.Refresh()
    $Window = $Process.MainWindowHandle
    if ($Window -eq 0) { throw 'Kaspire window did not start.' }
    [KaspireUi]::ShowWindow($Window, 3) | Out-Null
    $Root = [Windows.Automation.AutomationElement]::FromHandle($Window)
    function Press([string]$Label) {
        $Condition = New-Object Windows.Automation.PropertyCondition(
          [Windows.Automation.AutomationElement]::NameProperty, $Label,
          [Windows.Automation.PropertyConditionFlags]::IgnoreCase)
        for ($Attempt=0; $Attempt -lt 40; $Attempt++) {
            # This Flutter SDK exposes MSAA, not the optional UIA provider.
            if ([KaspireUi]::Press($Window, $Label)) {
                Start-Sleep -Milliseconds 500; return
            }
            $Element = $Root.FindFirst([Windows.Automation.TreeScope]::Descendants, $Condition)
            if ($Element) {
                $Pattern = $null
                if ($Element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$Pattern)) {
                    $Pattern.Invoke(); Start-Sleep -Milliseconds 500; return
                }
                if ($Element.TryGetCurrentPattern([Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$Pattern)) {
                    $Pattern.DoDefaultAction(); Start-Sleep -Milliseconds 500; return
                }
            }
            Start-Sleep -Milliseconds 250
        }
        throw "Visible in-app button not found/invokable: $Label"
    }
    function Input([string]$Title, [AllowEmptyString()][string]$Text) {
        for ($Attempt=0; $Attempt -lt 40; $Attempt++) {
            $Field = [KaspireUi]::Input($Window, $Title)
            if ($Field -ne [IntPtr]::Zero) {
                $Bounds = New-Object KaspireUi+Rect
                $ParentBounds = New-Object KaspireUi+Rect
                [KaspireUi]::GetWindowRect($Field, [ref]$Bounds) | Out-Null
                [KaspireUi]::GetWindowRect($Window, [ref]$ParentBounds) | Out-Null
                if ($Bounds.Right-$Bounds.Left -lt 150 -or $Bounds.Bottom-$Bounds.Top -lt 28 -or
                    $Bounds.Left -lt $ParentBounds.Left -or $Bounds.Right -gt $ParentBounds.Right -or
                    $Bounds.Top -lt $ParentBounds.Top -or $Bounds.Bottom -gt $ParentBounds.Bottom) {
                    throw 'Embedded secure field is clipped or too small.'
                }
                [KaspireUi]::SendMessage($Field, 0x000C, [IntPtr]::Zero, $Text) | Out-Null
                return $Field
            }
            Start-Sleep -Milliseconds 250
        }
        throw "Embedded in-app input not found: $Title"
    }
    # Only disposable CI input; never log values or capture recovery words.
    $TestPassword = 'Kaspire-Ui!42'
    Press 'Create 24-word Wallet'
    $PinField = Input 'Set Kaspire password' $TestPassword
    $PinFont = [KaspireUi]::SendMessage($PinField, 0x0031, [IntPtr]::Zero, $null)
    for ($Frame=0; $Frame -lt 40; $Frame++) {
        # No screenshots or plaintext values: verify the same masked native
        # field, its font and entered length survive several caret cycles.
        $CurrentFont = [KaspireUi]::SendMessage($PinField, 0x0031, [IntPtr]::Zero, $null)
        $Length = [KaspireUi]::SendMessage($PinField, 0x000E, [IntPtr]::Zero, $null)
        $Mask = [KaspireUi]::SendMessage($PinField, 0x00D2, [IntPtr]::Zero, $null)
        if (-not [KaspireUi]::IsWindowVisible($PinField) -or $CurrentFont -ne $PinFont -or
            $Length.ToInt32() -ne $TestPassword.Length -or $Mask.ToInt32() -eq 0) {
            throw 'The masked PIN field changed visibility, font or content during entry.'
        }
        Start-Sleep -Milliseconds 100
    }
    Press 'Show password'
    if (([KaspireUi]::SendMessage($PinField, 0x00D2, [IntPtr]::Zero, $null)).ToInt32() -ne 0) { throw 'Eye did not reveal the native password field.' }
    if (([KaspireUi]::SendMessage($PinField, 0x000E, [IntPtr]::Zero, $null)).ToInt32() -ne $TestPassword.Length) { throw 'Visibility toggle changed password content.' }
    Press 'Hide password'
    if (([KaspireUi]::SendMessage($PinField, 0x00D2, [IntPtr]::Zero, $null)).ToInt32() -eq 0) { throw 'Eye did not mask the native password field.' }
    Press 'Continue'
    $ConfirmationField = Input 'Confirm Kaspire password' $TestPassword
    if (([KaspireUi]::SendMessage($ConfirmationField, 0x00D2, [IntPtr]::Zero, $null)).ToInt32() -eq 0) { throw 'Password confirmation did not start masked.' }
    Press 'Continue'
    Input 'BIP39 passphrase (optional)' '' | Out-Null
    Press 'Cancel'
    Press 'Import Private Key'
    Input 'Unlock Kaspire' $TestPassword | Out-Null
    Press 'Continue'
    Input 'Import private key' '' | Out-Null
    Press 'Cancel'
    Press 'Import 12 / 24 Words'
    Input 'Unlock Kaspire' $TestPassword | Out-Null
    Press 'Continue'
    Input 'BIP39 passphrase (optional)' '' | Out-Null
    Press 'Continue'
    Input 'Import recovery phrase' '' | Out-Null
    Press 'Cancel'
    Press 'Create 24-word Wallet'
    Input 'Unlock Kaspire' $TestPassword | Out-Null
    Press 'Continue'
    Input 'BIP39 passphrase (optional)' '' | Out-Null
    Press 'Continue'
    for ($Attempt=0; $Attempt -lt 40; $Attempt++) {
        $Display = [KaspireUi]::Input($Window, 'Write down your recovery phrase')
        if ($Display -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($Display -eq [IntPtr]::Zero) { throw 'Native recovery display was not embedded.' }
    $DisposablePhrase = [KaspireUi]::Text($Display)
    if (($DisposablePhrase -split '\s+').Count -ne 24) { throw 'Creation did not generate 24 words.' }
    Press 'Done'
    Input 'Verify recovery phrase' $DisposablePhrase | Out-Null
    $DisposablePhrase = $null
    Press 'Continue'
    Start-Sleep -Seconds 3
    if (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'Kaspire\wallets.dpapi'))) { throw 'Native wallet was not saved.' }
    # Check the public catalogue, not only the PIN file (which existed earlier).
    # Individual signing secrets remain separately DPAPI-encrypted; never
    # decrypt, print or upload them in this check.
    Add-Type -AssemblyName System.Security
    $CatalogueBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        [IO.File]::ReadAllBytes((Join-Path $env:LOCALAPPDATA 'Kaspire\wallets.dpapi')),
        $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try {
        $Catalogue = [Text.Encoding]::UTF8.GetString($CatalogueBytes) | ConvertFrom-Json
        if (@($Catalogue.wallets).Count -ne 1 -or $Catalogue.active -ne $Catalogue.wallets[0].id -or
            $Catalogue.wallets[0].address -notmatch '^kaspa:') {
            throw 'The UI did not create and select the expected native wallet.'
        }
    } finally {
        [Array]::Clear($CatalogueBytes, 0, $CatalogueBytes.Length)
        $Catalogue = $null
    }
    # A cold start must lock, a wrong-case password must show an error, and
    # cancellation/retry must work without closing the application again.
    Stop-Process -Id $Process.Id
    $Process = Start-Process $Exe -WorkingDirectory (Split-Path $Exe -Parent) -PassThru -RedirectStandardOutput (Join-Path $DiagnosticRoot 'restart-out.log') -RedirectStandardError (Join-Path $DiagnosticRoot 'restart-error.log')
    Start-Sleep -Seconds 5
    $Process.Refresh(); $Window = $Process.MainWindowHandle
    if ($Window -eq 0) { throw 'Wallet did not reopen after creation.' }
    [KaspireUi]::ShowWindow($Window, 3) | Out-Null
    $Root = [Windows.Automation.AutomationElement]::FromHandle($Window)
    Press 'Unlock Kaspire'
    Input 'Unlock Kaspire' $TestPassword.ToLowerInvariant() | Out-Null
    Press 'Continue'
    Start-Sleep -Seconds 2
    if (([KaspireUi]::Buttons($Window) -join "`n") -notmatch 'Incorrect password') { throw 'Wrong password did not show a clear error.' }
    Press 'Unlock Kaspire'
    Input 'Unlock Kaspire' '' | Out-Null
    Press 'Cancel'
    Press 'Unlock Kaspire'
    Input 'Unlock Kaspire' $TestPassword | Out-Null
    Press 'Continue'
    Start-Sleep -Seconds 3
    if (([KaspireUi]::Buttons($Window) -join "`n") -notmatch 'Assets & Names') { throw 'Correct password did not unlock after wrong password/cancel.' }
    $TestPassword = $null
    # Capture public dashboard chrome only, never an open native secret field.
    $SecureFieldOpen = $false
    [KaspireUi]::EnumChildWindows($Window, { param($Handle, $Data)
      if ([KaspireUi]::Class($Handle) -eq 'KaspireEmbeddedSecureInput') { $script:SecureFieldOpen = $true }
      return $true
    }, [IntPtr]::Zero) | Out-Null
    if (-not $SecureFieldOpen) {
      Add-Type -AssemblyName System.Drawing
      $PublicBounds = New-Object KaspireUi+Rect
      [KaspireUi]::GetWindowRect($Window, [ref]$PublicBounds) | Out-Null
      $PublicShot = New-Object Drawing.Bitmap ($PublicBounds.Right-$PublicBounds.Left), ($PublicBounds.Bottom-$PublicBounds.Top)
      $PublicGraphics = [Drawing.Graphics]::FromImage($PublicShot)
      try {
        $PublicGraphics.CopyFromScreen($PublicBounds.Left, $PublicBounds.Top, 0, 0, $PublicShot.Size)
        $PublicShot.Save((Join-Path $DiagnosticRoot 'windows-dashboard.png'), [Drawing.Imaging.ImageFormat]::Png)
      } finally { $PublicGraphics.Dispose(); $PublicShot.Dispose() }
    }
    [KaspireUi]::Buttons($Window) | Set-Content (Join-Path $DiagnosticRoot 'windows-dashboard-buttons.txt') -Encoding UTF8
    foreach ($Destination in @('Send', 'Receive', 'Settings', 'Assets', 'Activity', 'UTXOs')) {
      [KaspireUi]::PublicNavigation($Window, $Destination)
      Start-Sleep -Seconds 2
      $PageLabels = [KaspireUi]::Buttons($Window)
      $PageLabels | Set-Content (Join-Path $DiagnosticRoot ('windows-page-' + $Destination.ToLowerInvariant() + '.txt')) -Encoding UTF8
      if ($Destination -eq 'Send' -and ($PageLabels -join "`n") -notmatch 'Send KAS') {
        throw 'The pointer click did not open Send in the content pane.'
      }
      if ($Destination -eq 'Activity' -and ($PageLabels -join "`n") -notmatch 'Activity') {
        throw 'Activity did not open in the content pane.'
      }
      if ($Destination -eq 'UTXOs' -and ($PageLabels -join "`n") -notmatch 'spendable output') {
        throw 'UTXOs did not open in the content pane.'
      }
      [KaspireUi]::PublicNavigation($Window, 'Wallet overview')
      Start-Sleep -Seconds 1
      if (([KaspireUi]::Buttons($Window) -join "`n") -notmatch 'Assets & Names') {
        throw 'Home did not return the right content pane to the asset overview.'
      }
    }
    'PASSED: mixed-case/symbol password setup; stable masked native field; native eye show/hide without content changes; confirmation starts masked; private-key/recovery input; 24-word creation; restart locks; wrong-case password shows an error; cancellation and correct retry unlock without restart; right-pane Send/Receive/Settings/Assets/Activity/UTXOs.' |
        Set-Content (Join-Path $DiagnosticRoot 'windows-dialog-checks.txt') -Encoding UTF8
} finally {
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id }
}
