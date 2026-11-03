using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class CubeLutTests
{
    private const string Invert = """
        TITLE "invert"
        # comment
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        LUT_3D_SIZE 2
        1 1 1
        0 1 1
        1 0 1
        0 0 1
        1 1 0
        0 1 0
        1 0 0
        0 0 0
        """;

    [Fact]
    public void ReadsATable()
    {
        var table = CubeLut.TryParse(Invert);
        Assert.NotNull(table);
        Assert.Equal(2, table.Size);
        Assert.Equal(0, table.Sample(1, 1, 1).R);
    }

    [Theory]
    [InlineData("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")]
    [InlineData("LUT_3D_SIZE 2\n0 0 0\n")]
    [InlineData("LUT_3D_SIZE 2\nnot numbers here\n")]
    [InlineData("hello")]
    [InlineData("")]
    [InlineData("LUT_3D_SIZE 129\n")]
    public void RefusesAnythingElse(string text) => Assert.Null(CubeLut.TryParse(text));
}
