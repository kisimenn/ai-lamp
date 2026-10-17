// AI通知ランプ 合図係（Windows）
//   フックから呼ばれたら、合図（種類と、フックから届いた文）を受付箱のフォルダに置くだけで、すぐ終わる。
//   常駐の係（lamp-watch.ps1）が受付箱を 0.1 秒ごとに見て、ランプに送る。
//   PowerShell は起動に数秒かかるパソコンがあるため（2026-10-17、別のパソコンで毎回 2〜5 秒）、毎回は起動しない。
//   常駐の係が動いていないときは、今までどおり PowerShell で lamp.ps1 を動かす（遅いが、光らないことはない）。
//
//   作り方: setup.ps1 が、Windows に最初から入っている C# の道具（csc.exe）で、このパソコンの中で作る
//   使い方: lamp-hook.exe <work|done|ask|error|end>   （フックの文は標準入力で受け取る）
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

static class LampHook
{
    static int Main(string[] args)
    {
        try
        {
            string kind = args.Length > 0 ? args[0] : "";
            if (Array.IndexOf(new[] { "work", "done", "ask", "error", "end" }, kind) < 0) return 0;

            byte[] input = new byte[0];
            if (Console.IsInputRedirected)
            {
                using (var ms = new MemoryStream())
                {
                    Console.OpenStandardInput().CopyTo(ms);
                    input = ms.ToArray();
                }
            }

            string home = Environment.GetEnvironmentVariable("USERPROFILE") ?? "";
            string dir = Environment.GetEnvironmentVariable("AI_LAMP_STATE_DIR");
            if (string.IsNullOrEmpty(dir)) dir = Path.Combine(home, ".cache", "ai-lamp");

            // 常駐の係が動いているか（係は名前付きの目印 Local\ai-lamp-watch を持っている）
            bool alive = false;
            if (Environment.GetEnvironmentVariable("AI_LAMP_NO_QUEUE") != "1")
            {
                try { using (Mutex.OpenExisting(@"Local\ai-lamp-watch")) { alive = true; } } catch { }
            }

            if (alive)
            {
                string q = Path.Combine(dir, "queue");
                Directory.CreateDirectory(q);
                // 名前に時刻を入れて、届いた順に処理できるようにする（書きかけを読まれないよう、書いてから名前を変える）
                string name = DateTime.UtcNow.Ticks.ToString("D20") + "-" + Process.GetCurrentProcess().Id + "." + kind;
                string tmp = Path.Combine(q, name + ".tmp");
                File.WriteAllBytes(tmp, input);
                File.Move(tmp, Path.Combine(q, name + ".json"));
                return 0;
            }

            // 常駐の係がいないとき: 今までどおり PowerShell で送る（窓は出さない・終わるのは待たない）
            string ps1 = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "lamp.ps1");
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + ps1 + "\" " + kind);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            var p = Process.Start(psi);
            p.StandardInput.BaseStream.Write(input, 0, input.Length);
            p.StandardInput.Close();
        }
        catch { }   // どんなときも AI の作業を止めない
        return 0;
    }
}
