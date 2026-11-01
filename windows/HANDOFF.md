# Windows Handoff Log

Shared log between the **writer** (macOS) and the **verifier** (Windows). Newest entry on top. See `AGENTS.md` §2.

## Template

```markdown
## <YYYY-MM-DD>, Phase <n>: <short title>

### Writer
- **Scope:** what was ported (Swift sources → C# files)
- **Built on macOS:** projects built / tests run and their result
- **How to verify:** exact steps and expected results (from `spec/08` §3 where possible)
- **Open VERIFY items:** file:line, what to check
- **Risks / unsure:** anything the verifier should look at first

### Verifier
- **Result:** PASS | FAIL
- **verify.ps1:** summary (build, tests, shaders)
- **Measurements:** frame timing, A/V offset, export speed, memory, SSIM, … (with machine: CPU, GPU, display Hz)
- **Changes made:** files and why
- **Spec updates:** ADRs or guide changes added
- **Next:** what the writer should do next
```

---

<!-- Entries start below this line. -->
