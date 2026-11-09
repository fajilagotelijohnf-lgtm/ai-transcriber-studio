using System;
using System.Runtime.InteropServices;
namespace AITranscriberInstaller {
 [StructLayout(LayoutKind.Sequential,Pack=4)] internal struct DesktopPropertyKey {public Guid Format;public uint Id;}
 [StructLayout(LayoutKind.Explicit,Size=24)] internal struct DesktopVariant {
  [FieldOffset(0)] public ushort Type;
  [FieldOffset(8)] public IntPtr Text;
 }
 [ComImport,Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface DesktopPropertyStore {
  [PreserveSig] int GetCount(out uint count);
  [PreserveSig] int GetAt(uint index,out DesktopPropertyKey key);
  [PreserveSig] int GetValue(ref DesktopPropertyKey key,out DesktopVariant value);
  [PreserveSig] int SetValue(ref DesktopPropertyKey key,ref DesktopVariant value);
  [PreserveSig] int Commit();
 }
 public static class DesktopIdentity {
  public const string AppId="AITranscriberStudio.Desktop";
  [DllImport("shell32.dll",CharSet=CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string value);
  [DllImport("shell32.dll")] static extern int GetCurrentProcessExplicitAppUserModelID(out IntPtr value);
  [DllImport("ole32.dll")] static extern int PropVariantClear(ref DesktopVariant value);
  public static void Apply(){Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(AppId));}
  public static string CurrentId(){IntPtr value;int hr=GetCurrentProcessExplicitAppUserModelID(out value);if(hr<0)return null;try{return Marshal.PtrToStringUni(value);}finally{Marshal.FreeCoTaskMem(value);}}
  static DesktopPropertyKey Key(){return new DesktopPropertyKey{Format=new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),Id=5};}
  internal static void ConfigureShortcut(object link){
   var store=(DesktopPropertyStore)link;var key=Key();var value=new DesktopVariant{Type=31,Text=Marshal.StringToCoTaskMemUni(AppId)};
   try{Marshal.ThrowExceptionForHR(store.SetValue(ref key,ref value));Marshal.ThrowExceptionForHR(store.Commit());}finally{Marshal.FreeCoTaskMem(value.Text);}
  }
  internal static string ShortcutId(object link){var key=Key();DesktopVariant value;Marshal.ThrowExceptionForHR(((DesktopPropertyStore)link).GetValue(ref key,out value));try{return value.Type==31?Marshal.PtrToStringUni(value.Text):null;}finally{PropVariantClear(ref value);}}
 }
}
