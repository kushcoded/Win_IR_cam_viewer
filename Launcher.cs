using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static void Main()
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "IRCameraViewer");
            Directory.CreateDirectory(dir);
            string ps1 = Path.Combine(dir, "IR-Camera-Viewer.ps1");
            try
            {
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("IR-Camera-Viewer.ps1"))
                using (FileStream f = new FileStream(ps1, FileMode.Create, FileAccess.Write, FileShare.Read))
                    s.CopyTo(f);
            }
            catch (IOException) { if (!File.Exists(ps1)) throw; } // another copy is running; reuse the file

            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + ps1 + "\" -IconPath \"" + Application.ExecutablePath + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "IR Camera Viewer", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
