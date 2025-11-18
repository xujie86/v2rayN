using System;
using System.IO;
using Avalonia;
using Avalonia.Media;

namespace v2rayN.Desktop.Common;

public static class AppBuilderExtension
{
    public static AppBuilder WithFontByDefault(this AppBuilder appBuilder)
    {
        if (!OperatingSystem.IsLinux())
        {
            var scUri = Path.Combine(Global.AvaAssets, "Fonts#Noto Sans SC");

            return appBuilder.With(new FontManagerOptions
            {
                FontFallbacks = new[]
                {
                    new FontFallback
                    {
                        FontFamily = new FontFamily(scUri)
                    }
                }
            });
        }

        var scLinuxUri    = Path.Combine(Global.AvaAssets, "Fonts#Noto Sans SC");
        var emojiLinuxUri = Path.Combine(Global.AvaAssets, "Fonts#Noto Color Emoji");

        return appBuilder.With(new FontManagerOptions
        {
            FontFallbacks = null
        });
    }
}
