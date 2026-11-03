using NativeScreen.Core;

namespace NativeScreen.Rendering.Tests;

public sealed class BundledWallpaperTests
{
    [Fact]
    public void AllWallpapersShipWithThumbnails()
    {
        var items = BundledWallpaperCatalog.AllItems.ToList();
        Assert.Equal(108, items.Count);
        Assert.Equal(items.Count, items.Select(item => item.Id).Distinct().Count());
        Assert.All(items, item =>
        {
            Assert.True(item.IsBundled);
            Assert.True(File.Exists(item.FullImagePath), item.FullImagePath);
            Assert.True(File.Exists(item.ThumbnailPath), item.ThumbnailPath);
        });
    }

    [Fact]
    public void ItemsSortByFileNameAndKnowTheirCategory()
    {
        var spring = BundledWallpaperCatalog.Items("Spring");
        Assert.Equal("spring-01", spring[0].Id);
        Assert.Equal(spring.Select(item => item.Id).Order(StringComparer.Ordinal), spring.Select(item => item.Id));
        Assert.Equal("Glassmorphism", BundledWallpaperCatalog.CategoryOf("glassmorphism-12"));
        Assert.Null(BundledWallpaperCatalog.CategoryOf("not a wallpaper"));
        Assert.Null(BundledWallpaperCatalog.CategoryOf(null));
    }
}
