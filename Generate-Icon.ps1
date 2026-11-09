$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
public static class TranscriberArtwork {
 static GraphicsPath Round(float x,float y,float w,float h,float r){var p=new GraphicsPath();p.AddArc(x,y,r*2,r*2,180,90);p.AddArc(x+w-r*2,y,r*2,r*2,270,90);p.AddArc(x+w-r*2,y+h-r*2,r*2,r*2,0,90);p.AddArc(x,y+h-r*2,r*2,r*2,90,90);p.CloseFigure();return p;}
 static Bitmap Render(int size){
  var b=new Bitmap(size,size,PixelFormat.Format32bppArgb);
  using(var g=Graphics.FromImage(b)){
   g.Clear(Color.Transparent);g.SmoothingMode=SmoothingMode.AntiAlias;g.PixelOffsetMode=PixelOffsetMode.HighQuality;g.ScaleTransform(size/256f,size/256f);
   using(var tile=Round(8,8,240,240,55))using(var blue=new LinearGradientBrush(new Point(20,12),new Point(236,248),Color.FromArgb(58,139,255),Color.FromArgb(30,66,203)))g.FillPath(blue,tile);
   using(var bubble=Round(43,53,170,126,29))g.FillPath(Brushes.White,bubble);
   using(var tail=new GraphicsPath()){tail.AddPolygon(new[]{new PointF(98,168),new PointF(98,207),new PointF(145,168)});g.FillPath(Brushes.White,tail);}
   using(var ink=new SolidBrush(Color.FromArgb(39,99,225))){float[] heights={29,54,78,54,29};for(int i=0;i<5;i++)using(var bar=Round(72+i*24,116-heights[i]/2,14,heights[i],7))g.FillPath(ink,bar);}
  }
  return b;
 }
 public static void Generate(string directory){
  int[] sizes={16,20,24,32,48,64,128,256};var frames=new byte[sizes.Length][];
  for(int i=0;i<sizes.Length;i++)using(var b=Render(sizes[i]))using(var m=new MemoryStream()){b.Save(m,ImageFormat.Png);frames[i]=m.ToArray();}
  using(var file=File.Create(Path.Combine(directory,"Transcriber.ico")))using(var w=new BinaryWriter(file)){
   w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)sizes.Length);int offset=6+16*sizes.Length;
   for(int i=0;i<sizes.Length;i++){w.Write((byte)(sizes[i]==256?0:sizes[i]));w.Write((byte)(sizes[i]==256?0:sizes[i]));w.Write((byte)0);w.Write((byte)0);w.Write((ushort)1);w.Write((ushort)32);w.Write(frames[i].Length);w.Write(offset);offset+=frames[i].Length;}
   foreach(var frame in frames)w.Write(frame);
  }
  using(var b=Render(512))b.Save(Path.Combine(directory,"Transcriber-Logo.png"),ImageFormat.Png);
  using(var sheet=new Bitmap(780,220))using(var g=Graphics.FromImage(sheet))using(var font=new Font("Segoe UI",11)){
   g.Clear(Color.FromArgb(242,245,251));int x=20;
   foreach(int size in new[]{16,24,32,48,64,128,256}){int preview=Math.Min(size,128);using(var b=Render(size))g.DrawImage(b,new Rectangle(x,30,preview,preview));g.DrawString(size+" px",font,Brushes.DarkSlateGray,x,177);x+=preview+25;}
   sheet.Save(Path.Combine(directory,"Transcriber-Icon-Preview.png"),ImageFormat.Png);
  }
 }
}
'@
[TranscriberArtwork]::Generate((Join-Path $PSScriptRoot 'resources'))
'Generated multi-resolution Windows icon and logo previews'
