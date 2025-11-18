using System;
using System.Reflection;
using Avalonia;
using Avalonia.Media;

namespace v2rayN.Desktop.Common;

public static class AppBuilderExtension
{
    public static AppBuilder WithFontByDefault(this AppBuilder appBuilder)
    {
        var asmName = Assembly.GetExecutingAssembly().GetName().Name 
                      ?? "v2rayN";

        var notoScUri = $"avares://{asmName}/Assets/Fonts#Noto Sans SC";

        var notoEmojiUri = $"avares://{asmName}/Assets/Fonts#Noto Color Emoji";

        if (!OperatingSystem.IsLinux())
        {
            return appBuilder.With(new FontManagerOptions
            {
                FontFallbacks = new[]
                {
                    new FontFallback
                    {
                        FontFamily = new FontFamily(notoScUri)
                    }
                }
            });
        }

        return appBuilder.With(new FontManagerOptions
        {
            DefaultFamilyName = notoScUri,
            FontFallbacks = new[]
            {
                new FontFallback
                {
                    FontFamily = new FontFamily(notoEmojiUri)
                },
                new FontFallback
                {
                    FontFamily = new FontFamily(notoScUri)
                }
            }
        });
    }
}
