using System.Text.Json.Nodes;
using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class McpDocumentTests
{
    private static JsonObject Json(string text) => (JsonObject)JsonNode.Parse(text)!;

    [Fact]
    public void MergePatchFollowsRfc7386()
    {
        var target = Json("""{"a":"b","c":{"d":"e","f":"g"},"keep":[1,2]}""");
        var patch = Json("""{"a":"z","c":{"f":null,"h":1},"keep":[3],"new":true}""");
        var merged = McpDocument.MergePatch(target, patch)!.ToJsonString();
        Assert.Equal("""{"a":"z","c":{"d":"e","h":1},"keep":[3],"new":true}""", merged);
        Assert.Equal("""{"a":"b","c":{"d":"e","f":"g"},"keep":[1,2]}""", target.ToJsonString());
    }

    [Fact]
    public void AWholeDocumentPatchKeepsTheIdAndRejectsBadValuesWithTheirPath()
    {
        var document = new ProjectDocument { Id = "doc", Name = "Old" };
        var next = McpDocument.Patch(document, Json("""{"name":"New","id":"other","background":{"type":"solid","solidColor":"#FF0000"}}"""));
        Assert.Equal("New", next.Name);
        Assert.Equal("doc", next.Id);
        Assert.Equal(BackgroundType.Solid, next.Background.Type);
        Assert.Equal("#FF0000", next.Background.SolidColor);

        var error = Assert.Throws<McpToolException>(() => McpDocument.Patch(document, Json("""{"background":{"type":"plaid"}}""")));
        Assert.Contains("background.type", error.Message);
        Assert.Equal("Old", document.Name);

        // A number is not an enum value: the macOS app could not read it back.
        error = Assert.Throws<McpToolException>(() => McpDocument.Patch(document, Json("""{"canvas":{"aspectRatioPreset":7}}""")));
        Assert.Contains("canvas.aspectRatioPreset", error.Message);
    }

    [Fact]
    public void AnItemPatchChangesOnlyThatItemAndKeepsItsId()
    {
        var document = new ProjectDocument();
        document.Timeline.Zooms =
        [
            new ZoomBlock { Id = "z1", SourceStartMs = 1000, SourceEndMs = 2000 },
            new ZoomBlock { Id = "z2", SourceStartMs = 3000, SourceEndMs = 4000 }
        ];
        var next = McpDocument.PatchItem(document, "zoom", "z2", Json("""{"scale":2.5,"id":"x","mode":"manual"}"""));
        var zoom = next.Timeline.Zooms.Single(item => item.Id == "z2");
        Assert.Equal(2.5, zoom.Scale);
        Assert.Equal(ZoomMode.Manual, zoom.Mode);
        Assert.Equal(1.8, next.Timeline.Zooms.Single(item => item.Id == "z1").Scale);
    }

    [Fact]
    public void AnItemPatchThatOverlapsAnotherOneIsRefused()
    {
        var document = new ProjectDocument();
        document.Timeline.Zooms =
        [
            new ZoomBlock { Id = "z1", SourceStartMs = 1000, SourceEndMs = 2000 },
            new ZoomBlock { Id = "z2", SourceStartMs = 3000, SourceEndMs = 4000 }
        ];
        var error = Assert.Throws<McpToolException>(() => McpDocument.PatchItem(document, "zoom", "z2", Json("""{"sourceStartMs":1500}""")));
        Assert.Contains("z1", error.Message);

        // Touching is fine.
        var next = McpDocument.PatchItem(document, "zoom", "z2", Json("""{"sourceStartMs":2000}"""));
        Assert.Equal(2000, next.Timeline.Zooms.Single(item => item.Id == "z2").SourceStartMs);
    }

    [Fact]
    public void MasksAndCaptionsArePatchedInsideTheirTracks()
    {
        var document = new ProjectDocument();
        document.Timeline.MaskTracks = [new MaskTrack { Id = "t", Items = [new MaskItem { Id = "m", SourceStartMs = 0, SourceEndMs = 1000 }] }];
        document.Captions.CaptionTracks = [new CaptionTrack { Id = "c" }];
        document.Captions.CaptionBlocks = [new CaptionBlock { Id = "b", TrackId = "c", SourceStartMs = 0, SourceEndMs = 500 }];
        var next = McpDocument.PatchItem(document, "mask", "m", Json("""{"type":"spotlight","intensity":50}"""));
        Assert.Equal(MaskType.Spotlight, next.Timeline.MaskTracks[0].Items[0].Type);
        next = McpDocument.PatchItem(next, "caption", "b", Json("""{"sourceEndMs":800}"""));
        Assert.Equal(800, next.Captions.CaptionBlocks[0].SourceEndMs);
        Assert.Throws<McpToolException>(() => McpDocument.PatchItem(next, "mask", "nope", Json("{}")));
        Assert.Throws<McpToolException>(() => McpDocument.PatchItem(next, "sparkle", "m", Json("{}")));
    }

    [Fact]
    public void ToolDefinitionsInlineTheirSharedDefinitions()
    {
        var (instructions, tools) = McpDocument.LoadTools("""
            {"instructions":"hi","definitions":{"project":{"type":"string","description":"p"}},
             "tools":[{"name":"t","inputSchema":{"type":"object","properties":{"project":{"$ref":"#/definitions/project"}}}}]}
            """);
        Assert.Equal("hi", instructions);
        Assert.Equal("""{"type":"string","description":"p"}""", tools[0]!["inputSchema"]!["properties"]!["project"]!.ToJsonString());
    }

    [Fact]
    public void TheSharedToolFileLoadsWithEveryTool()
    {
        // Found by walking up from the test output, whatever the configuration and platform folders are.
        var folder = new DirectoryInfo(AppContext.BaseDirectory);
        while (folder is not null && !File.Exists(Path.Combine(folder.FullName, "NativeScreen", "NativeScreen", "Resources", "MCPTools.json")))
        {
            folder = folder.Parent;
        }

        Assert.NotNull(folder);
        var path = Path.Combine(folder.FullName, "NativeScreen", "NativeScreen", "Resources", "MCPTools.json");
        var (instructions, tools) = McpDocument.LoadTools(File.ReadAllText(path));
        Assert.NotEmpty(instructions);
        Assert.Equal(28, tools.Count);
        Assert.DoesNotContain("$ref", tools.ToJsonString());
    }

    [Fact]
    public void ArgumentsAreCheckedAgainstTheSchema()
    {
        var (_, tools) = McpDocument.LoadTools("""
            {"instructions":"","tools":[
             {"name":"delete_project","inputSchema":{"type":"object","properties":{"project":{"type":"string"},"confirm":{"type":"boolean"}},"required":["confirm"]}},
             {"name":"get_status","inputSchema":{"type":"object","properties":{}}}]}
            """);

        McpDocument.ValidateArguments(tools, "delete_project", Json("""{"confirm":true,"project":"a"}"""));

        var error = Assert.Throws<McpToolException>(() => McpDocument.ValidateArguments(tools, "delete_project", Json("""{"confirm":true,"projct":"a"}""")));
        Assert.Equal("Unknown argument projct for delete_project. It accepts: confirm, project.", error.Message);

        error = Assert.Throws<McpToolException>(() => McpDocument.ValidateArguments(tools, "get_status", Json("""{"x":1}""")));
        Assert.Equal("Unknown argument x for get_status. It accepts: no arguments.", error.Message);

        Assert.Equal("Missing argument: confirm", Assert.Throws<McpToolException>(() => McpDocument.ValidateArguments(tools, "delete_project", Json("{}"))).Message);
        Assert.Equal("Missing argument: confirm", Assert.Throws<McpToolException>(() => McpDocument.ValidateArguments(tools, "delete_project", Json("""{"confirm":""}"""))).Message);
        Assert.Equal("Missing argument: confirm", Assert.Throws<McpToolException>(() => McpDocument.ValidateArguments(tools, "delete_project", Json("""{"confirm":null}"""))).Message);
    }

    [Fact]
    public void EnumOptionsUseTheFileNames()
    {
        var options = McpDocument.EnumOptions();
        Assert.Contains("manual", options["timeline.zooms[].mode"]!.AsArray().Select(item => item!.GetValue<string>()));
        Assert.Equal(ZoomMode.Manual, McpDocument.Parse<ZoomMode>("manual"));
        Assert.Null(McpDocument.Parse<ZoomMode>("nope"));
        Assert.Equal(25, options.Count);
    }

    [Fact]
    public void ItemIdsFindWhatAnAddCreated()
    {
        var document = new ProjectDocument();
        var before = McpDocument.ItemIds(document);
        document.Timeline.Zooms.Add(new ZoomBlock { Id = "new" });
        Assert.Equal(["new"], McpDocument.ItemIds(document).Except(before));
    }
}
