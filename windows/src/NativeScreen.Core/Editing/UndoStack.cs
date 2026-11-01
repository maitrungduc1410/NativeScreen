namespace NativeScreen.Core;

public sealed class UndoStack
{
    public const int MaxDepth = 150;
    private readonly List<string> undo = [];
    private readonly List<string> redo = [];

    public UndoStack(ProjectDocument document)
    {
        Current = ProjectJson.Clone(document);
    }

    public ProjectDocument Current { get; private set; }
    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;

    public void Commit(ProjectDocument next)
    {
        undo.Add(ProjectJson.Serialize(Current));
        if (undo.Count > MaxDepth)
        {
            undo.RemoveAt(0);
        }

        redo.Clear();
        Current = ProjectJson.Clone(next);
    }

    public void Undo()
    {
        if (undo.Count == 0)
        {
            return;
        }

        redo.Add(ProjectJson.Serialize(Current));
        Current = ProjectJson.Deserialize<ProjectDocument>(undo[^1]);
        undo.RemoveAt(undo.Count - 1);
    }

    public void Redo()
    {
        if (redo.Count == 0)
        {
            return;
        }

        undo.Add(ProjectJson.Serialize(Current));
        Current = ProjectJson.Deserialize<ProjectDocument>(redo[^1]);
        redo.RemoveAt(redo.Count - 1);
    }
}
