import SwiftUI

/// GitLab: 브랜치·변수로 새 파이프라인 / GitHub: workflow_dispatch 워크플로를 브랜치·입력값으로 실행.
/// With a commit of the branch chosen, that commit's own run starts again: a GitLab job is pressed, a GitHub run re-run.
struct RunPipelineSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @ViewState private var ref = ""
    /// The branch's commits with runs on it; nil runs on the branch's tip as it is when the run starts
    @ViewState private var commits: [RunCommit] = []
    @ViewState private var sha: String?
    /// GitLab: the chosen commit's pipeline jobs, manual ones first, and the one to press
    @ViewState private var jobs: [CIJob] = []
    @ViewState private var jobName: String?
    /// GitHub: the chosen commit's workflow run to re-run
    @ViewState private var runID: Int?
    @ViewState private var variables: [Variable] = []
    @ViewState private var workflows: [CIWorkflow] = []
    @ViewState private var workflowID: Int?
    @ViewState private var values: [String: String] = [:]
    @ViewState private var loading = false
    @ViewState private var loadError: String?
    /// Run later: the app starts the run itself at `runAt`
    @ViewState private var later = false
    @ViewState private var runAt = ScheduledRuns.nextFullHour(after: Date())
    /// Redraws the time check when the primary button found the time already gone
    @ViewState private var checkedAt = Date()

    struct Variable: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        var description = ""
        var options: [String] = []
        /// .gitlab-ci.yml 에서 온 변수(이름 고정)
        var fixed = false
    }

    private var provider: Provider { store.target?.provider ?? .gitlab }
    private var workflow: CIWorkflow? { workflows.first { $0.id == workflowID } }
    private var commit: RunCommit? { sha.flatMap { s in commits.first { $0.sha == s } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(provider == .gitlab ? "Run pipeline" : "Run workflow").font(.title3.weight(.semibold))
            LabeledContent("Branch") {
                let branches = store.ciBranches
                if branches.isEmpty {
                    TextField("Branch name", text: $ref).textFieldStyle(.roundedBorder)
                } else {
                    Picker("", selection: $ref) {
                        ForEach(branches, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            commitForm
            if let commit {
                if provider == .gitlab { jobForm(commit) } else { rerunForm(commit) }
            } else if provider == .gitlab {
                gitlabForm
            } else {
                githubForm
            }
            whenForm
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // the reason sits beside the primary it disables
                if later, !timeOK {
                    Text("Choose a time in the future.").font(.caption).foregroundStyle(.secondary)
                }
                Button { run() } label: { later ? Text("Schedule run") : Text("Run") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun || (later && !timeOK))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: setup)
        .onChange(of: ref) { _, _ in
            sha = nil
            Task { await loadCommits() }
            if provider == .github { Task { await loadWorkflows() } }
        }
        .onChange(of: sha) { _, _ in pickCommit() }
    }

    // MARK: Commit

    /// The branch's tip by default, or one of its commits that already has runs on the branch
    private var commitForm: some View {
        LabeledContent("Commit") {
            Picker("", selection: $sha) {
                Text("Latest on \(ref)").tag(String?.none)
                if !commits.isEmpty { Divider() }
                ForEach(commits) { c in Text(verbatim: commitLabel(c)).tag(String?.some(c.sha)) }
            }
            .labelsHidden()
        }
    }

    private func commitLabel(_ c: RunCommit) -> String {
        var parts = [c.short + "  " + c.subject]
        if let created = c.created { parts.append(ListDate.when(created, locale: locale)) }
        return parts.joined(separator: " · ")
    }

    /// GitLab: which job of the commit's pipeline to press
    @ViewBuilder private func jobForm(_ commit: RunCommit) -> some View {
        if jobs.isEmpty {
            Text(loading ? "Reading the jobs…" : "This pipeline has no jobs.").font(.callout).foregroundStyle(.secondary)
        } else {
            LabeledContent("Job") {
                Picker("", selection: $jobName) {
                    ForEach(jobs) { job in Text(verbatim: job.name + " · " + job.status.title).tag(String?.some(job.name)) }
                }
                .labelsHidden()
            }
            let manual = jobs.first { $0.name == jobName }?.canPlay ?? true
            Text(manual ? LocalizedStringKey("Presses this job in the pipeline of \(commit.short) on \(ref).")
                        : LocalizedStringKey("Runs this job again in the pipeline of \(commit.short) on \(ref)."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// GitHub: which of the commit's workflow runs to re-run; its inputs can't change
    @ViewBuilder private func rerunForm(_ commit: RunCommit) -> some View {
        LabeledContent("Workflow run") {
            Picker("", selection: $runID) {
                ForEach(RunCommits.workflowRuns(commit)) { r in
                    Text(verbatim: r.name + " · " + String(localized: "run #\(String(r.number))")).tag(Int?.some(r.id))
                }
            }
            .labelsHidden()
        }
        Text("Re-runs this run of \(commit.short) on \(ref) with its original inputs.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func loadCommits() async {
        let r = ref.trimmed
        let list = (try? await store.ciCommits(branch: r)) ?? []
        guard r == ref.trimmed else { return }
        commits = list
    }

    /// A chosen commit starts on its first manual job (GitLab) or its newest workflow run (GitHub)
    private func pickCommit() {
        jobs = []
        jobName = nil
        runID = nil
        guard let commit else { return }
        if provider == .github {
            runID = RunCommits.workflowRuns(commit).first?.id
            return
        }
        guard let pipeline = commit.runs.first?.id else { return }
        let chosen = commit.sha
        Task {
            loading = true
            defer { loading = false }
            let list = (try? await store.ciCommitJobs(pipeline: pipeline)) ?? []
            guard sha == chosen else { return }
            jobs = list
            jobName = RunCommits.defaultJob(list)?.name
        }
    }

    // MARK: GitLab

    private var gitlabForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Variables").font(.subheadline.weight(.semibold))
                Spacer()
                Button { variables.append(Variable(key: "", value: "")) } label: { DesignIconImage(icon: .plus) }
                    .buttonStyle(.borderless)
                    .help("Add variable")
            }
            if variables.isEmpty {
                Text("Runs without variables.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($variables) { $v in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if v.fixed {
                                    Text(v.key).font(.callout.monospaced()).frame(width: 160, alignment: .leading).lineLimit(1)
                                } else {
                                    TextField("Name", text: $v.key).textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(width: 160)
                                }
                                if v.options.isEmpty {
                                    TextField("Value", text: $v.value).textFieldStyle(.roundedBorder)
                                } else {
                                    Picker("", selection: $v.value) {
                                        ForEach(v.options, id: \.self) { Text($0).tag($0) }
                                    }
                                    .labelsHidden()
                                }
                                Button { variables.removeAll { $0.id == v.id } } label: { SymbolIcon("minus.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Remove this variable")
                            }
                            if !v.description.isEmpty {
                                Text(v.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    // MARK: GitHub

    @ViewBuilder private var githubForm: some View {
        if let loadError {
            Text(loadError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        } else if workflows.isEmpty {
            Text(loading ? "Reading the workflow…" : "This branch has no workflow with 'Run workflow' (workflow_dispatch).")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            LabeledContent("Workflow") {
                Picker("", selection: Binding(get: { workflowID ?? workflows[0].id }, set: { pick($0) })) {
                    ForEach(workflows) { w in Text(w.name).tag(w.id) }
                }
                .labelsHidden()
            }
            if let w = workflow, !w.inputs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(w.inputs) { input in inputField(input) }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    @ViewBuilder private func inputField(_ input: CIInput) -> some View {
        let binding = Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })
        VStack(alignment: .leading, spacing: 3) {
            switch input.type {
            case "boolean":
                Toggle(isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" })) {
                    Text(input.description.isEmpty ? input.name : input.description)
                }
            case "choice" where !input.options.isEmpty:
                Text(label(input)).font(.callout)
                Picker("", selection: binding) {
                    ForEach(input.options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            default:
                Text(label(input)).font(.callout)
                TextField(input.name, text: binding).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func label(_ i: CIInput) -> String {
        (i.description.isEmpty ? i.name : i.description) + (i.required ? " *" : "")
    }

    // MARK: Run later

    /// Run now or at a date and time; the app keeps the run and starts it then (ScheduledRunStore)
    @ViewBuilder private var whenForm: some View {
        Picker("", selection: $later) {
            Text("Run now").tag(false)
            Text("Run later").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        if later {
            LabeledContent("Run at") {
                DatePicker("", selection: $runAt, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
            }
            Text("Gitrochi starts the run at this time if it is open. Otherwise the run is marked missed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var timeOK: Bool { ScheduledRuns.canSchedule(runAt, now: max(checkedAt, Date())) }

    // MARK: 동작

    private var canRun: Bool {
        guard !ref.trimmed.isEmpty else { return false }
        if commit != nil { return commitRun != nil }
        if provider == .gitlab { return true }
        guard let w = workflow else { return false }
        return w.inputs.allSatisfy { !$0.required || !(values[$0.name] ?? "").trimmed.isEmpty || $0.type == "boolean" }
    }

    /// What starts again for the chosen commit
    private var commitRun: CommitRun? {
        guard let commit else { return nil }
        if provider == .github { return runID.map { CommitRun(runID: $0, jobName: nil) } }
        guard let pipeline = commit.runs.first?.id, let jobName, jobs.contains(where: { $0.name == jobName }) else { return nil }
        return CommitRun(runID: pipeline, jobName: jobName)
    }

    private func setup() {
        ref = store.ciBranches.first ?? store.ciCurrentRef ?? ""
        if provider == .gitlab {
            variables = store.gitlabPipelineVariables().map {
                Variable(key: $0.name, value: $0.defaultValue, description: $0.description, options: $0.options, fixed: true)
            }
        }
    }

    private func loadWorkflows() async {
        let r = ref
        guard !r.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await store.ciWorkflows(ref: r)
            guard r == ref else { return }
            loadError = nil
            workflows = list
            pick(list.first { $0.id == workflowID }?.id ?? list.first?.id)
        } catch {
            loadError = store.describe(error)
            workflows = []
        }
    }

    private func pick(_ id: Int?) {
        workflowID = id
        var v: [String: String] = [:]
        for i in workflows.first(where: { $0.id == id })?.inputs ?? [] {
            v[i.name] = values[i.name] ?? (i.defaultValue.isEmpty && i.type == "choice" ? i.options.first ?? "" : i.defaultValue)
            if i.type == "boolean", v[i.name] != "true" { v[i.name] = "false" }
        }
        values = v
    }

    private func run() {
        let r = ref.trimmed
        if later {
            checkedAt = Date()
            guard timeOK else { return }
        }
        if let commit, let target = commitRun {
            if later {
                let name = provider == .github ? commit.runs.first(where: { $0.id == target.runID })?.name : nil
                schedule(ref: r) { $0.sha = commit.sha; $0.runID = target.runID; $0.jobName = target.jobName; $0.workflowName = name }
                return
            }
            dismiss()
            Task { await store.runOnCommit(target) }
        } else if provider == .gitlab {
            let vars = variables.map { ($0.key.trimmed, $0.value) }.filter { !$0.0.isEmpty }
            if later {
                let pairs = vars.map { ScheduledRun.Variable(key: $0.0, value: $0.1) }
                schedule(ref: r) { $0.variables = pairs }
                return
            }
            dismiss()
            Task { await store.runPipeline(ref: r, variables: vars) }
        } else if let w = workflow {
            let inputs = values.filter { k, v in !v.isEmpty && w.inputs.contains { $0.name == k } }
            if later {
                schedule(ref: r) { $0.workflowID = w.id; $0.workflowName = w.name; $0.inputs = inputs }
                return
            }
            dismiss()
            Task { await store.runWorkflow(w, ref: r, inputs: inputs) }
        }
    }

    /// Keeps the run with this repository and its account (never the token) for the app to start at `runAt`
    private func schedule(ref r: String, _ fill: (inout ScheduledRun) -> Void) {
        guard let target = store.target, let account = store.hostingAccount, let path = store.url?.path else { return }
        var run = ScheduledRun(repoPath: path, provider: target.provider, host: target.host, remote: target.remote, path: target.path,
                               accountID: account.id, ref: r, runAt: runAt)
        fill(&run)
        ScheduledRunStore.shared.add(run)
        dismiss()
    }
}
