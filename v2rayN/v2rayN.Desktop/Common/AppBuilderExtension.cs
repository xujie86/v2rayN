using System;
using System.Collections.Generic;
using System.IO;
using Avalonia.Media;

namespace v2rayN.Desktop.Common;

public static class AppBuilderExtension
{
    public static AppBuilder WithFontByDefault(this AppBuilder appBuilder)
    {
        var scUri = Path.Combine(Global.AvaAssets, "Fonts#Noto Sans SC");

        if (!OperatingSystem.IsLinux())
        {
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

        var fallbacks = new List<FontFallback>();

        var emojiUri = Path.Combine(Global.AvaAssets, "Fonts#Noto Color Emoji");
        fallbacks.Add(new FontFallback
        {
            FontFamily = new FontFamily(emojiUri)
        });

        fallbacks.Add(new FontFallback
        {
            FontFamily = new FontFamily(scUri)
        });

        return appBuilder.With(new FontManagerOptions
        {
            FontFallbacks = fallbacks.ToArray()
        });
    }
}
