import SwiftUI

struct OpenSourceLicensesView: View {
    private let notices: [ThirdPartyNotice]
    private let buildMetadata: AppBuildMetadata
    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    init(
        notices: [ThirdPartyNotice] = ThirdPartyNoticeCatalog.notices(),
        buildMetadata: AppBuildMetadata = AppBuildMetadata()
    ) {
        self.notices = notices
        self.buildMetadata = buildMetadata
    }

    var body: some View {
        List {
            Section("SSH App") {
                NoticeMetadataRow(title: "Version", value: buildMetadata.sourceVersion)
                    .accessibilityIdentifier("licenses.app.version")

                Link(destination: buildMetadata.repositoryURL) {
                    NoticeMetadataRow(title: "GitHub", value: buildMetadata.repositoryDisplayName)
                }
                .accessibilityIdentifier("licenses.app.repository")

                if let commitURL = buildMetadata.sourceCommitURL {
                    Link(destination: commitURL) {
                        NoticeMetadataRow(title: "Commit", value: buildMetadata.shortSourceCommit)
                    }
                    .accessibilityIdentifier("licenses.app.commit")
                } else {
                    NoticeMetadataRow(title: "Commit", value: buildMetadata.shortSourceCommit)
                        .accessibilityIdentifier("licenses.app.commit")
                }

                NavigationLink {
                    AppLicenseDetailView()
                } label: {
                    NoticeMetadataRow(title: "License", value: AppBuildMetadata.licenseName)
                }
                .accessibilityIdentifier("licenses.app.license")
            }
            .themedListRow(palette)

            Section {
                ForEach(notices) { notice in
                    NavigationLink {
                        ThirdPartyNoticeDetailView(notice: notice)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.name)
                                .foregroundStyle(palette.primaryText)

                            Text(notice.licenseName)
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("licenses.notice.\(notice.id)")
                }
            } footer: {
                Text("Licenses and notices for open source components bundled with SSH App.")
            }
            .themedListRow(palette)
        }
        .themedListBackground(palette)
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppLicenseDetailView: View {
    @State private var licenseText = ""

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        List {
            Section("SSH App") {
                NoticeMetadataRow(title: "License", value: AppBuildMetadata.licenseName)
                NoticeMetadataRow(title: "Copyright", value: "Copyright (c) 2026 Clarified Labs, Inc.")
            }
            .themedListRow(palette)

            Section("Notice") {
                Text(verbatim: licenseText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .themedListRow(palette)
        }
        .themedListBackground(palette)
        .navigationTitle(AppBuildMetadata.licenseName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            licenseText = AppBuildMetadata.licenseText()
        }
    }
}

private struct ThirdPartyNoticeDetailView: View {
    let notice: ThirdPartyNotice
    @State private var licenseText = ""

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        List {
            Section("Dependency") {
                NoticeMetadataRow(title: "License", value: notice.licenseName)
                NoticeMetadataRow(title: "Version", value: notice.version)
                NoticeMetadataRow(title: "Included in app", value: notice.shippedInApp ? "Yes" : "No")

                if let sourceURL = notice.sourceURL {
                    Link(destination: sourceURL) {
                        NoticeMetadataRow(title: "Source", value: notice.source)
                    }
                }
            }
            .themedListRow(palette)

            Section("Purpose") {
                Text(notice.purpose)

                if let notes = notice.notes {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .themedListRow(palette)

            Section("Notice") {
                Text(verbatim: notice.copyright)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)

                Text(verbatim: licenseText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .themedListRow(palette)
        }
        .themedListBackground(palette)
        .navigationTitle(notice.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: notice.id) {
            licenseText = ThirdPartyNoticeCatalog.licenseText(for: notice)
        }
    }
}

private struct NoticeMetadataRow: View {
    let title: String
    let value: String

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

            Text(verbatim: value)
                .font(.footnote)
                .foregroundStyle(palette.primaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    NavigationStack {
        OpenSourceLicensesView()
    }
}
