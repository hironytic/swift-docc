/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021-2024 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation

@_spi(ExternalLinks) // SPI to set `context.linkResolver.dependencyArchives`
@_spi(FileManagerProtocol) // SPI to initialize `DiagnosticConsoleWriter` with a `FileManagerProtocol`
import SwiftDocC

/// An action that converts a source bundle into compiled documentation.
public struct ConvertAction: Action, RecreatingContext {
    enum Error: DescribedError {
        case doesNotContainBundle(url: URL)
        case cancelPending
        var errorDescription: String {
            switch self {
            case .doesNotContainBundle(let url):
                return """
                    The directory at '\(url)' and its subdirectories do not contain at least one valid documentation \
                    bundle. A documentation bundle is a directory ending in `.docc`. Pass \
                    `--allow-arbitrary-catalog-directories` flag to convert a directory without a `.docc` extension.
                    """
            case .cancelPending:
                return "The action is already in the process of being cancelled."
            }
        }
    }

    let rootURL: URL?
    let outOfProcessResolver: OutOfProcessReferenceResolver?
    let analyze: Bool
    let targetDirectory: URL
    let htmlTemplateDirectory: URL?
    let emitDigest: Bool
    let inheritDocs: Bool
    let treatWarningsAsErrors: Bool
    let experimentalEnableCustomTemplates: Bool
    let experimentalModifyCatalogWithGeneratedCuration: Bool
    let buildLMDBIndex: Bool
    let documentationCoverageOptions: DocumentationCoverageOptions
    let diagnosticLevel: DiagnosticSeverity
    let diagnosticEngine: DiagnosticEngine

    let transformForStaticHosting: Bool
    let hostingBasePath: String?
    
    let sourceRepository: SourceRepository?
    
    private(set) var context: DocumentationContext {
        didSet {
            // current platforms?

            switch documentationCoverageOptions.level {
            case .detailed, .brief:
                self.context.shouldStoreManuallyCuratedReferences = true
            case .none:
                break
            }
        }
    }
    private let workspace: DocumentationWorkspace
    private var currentDataProvider: DocumentationWorkspaceDataProvider?
    private var injectedDataProvider: DocumentationWorkspaceDataProvider?
    private var fileManager: FileManagerProtocol
    private let temporaryDirectory: URL
    
    public var setupContext: ((inout DocumentationContext) -> Void)? {
        didSet {
            converter.setupContext = setupContext
        }
    }
    
    var converter: DocumentationConverter
    
    private var durationMetric: Benchmark.Duration?
    private let diagnosticWriterOptions: (formatting: DiagnosticFormattingOptions, baseURL: URL)

    /// Initializes the action with the given validated options, creates or uses the given action workspace & context.
    /// - Parameter buildIndex: Whether or not the convert action should emit an LMDB representation
    ///   of the navigator index.
    ///
    ///   A JSON representation is built and emitted regardless of this value.
    /// - Parameter workspace: A provided documentation workspace. Creates a new empty workspace if value is `nil`
    /// - Parameter context: A provided documentation context. Creates a new empty context in the workspace if value is `nil`
    /// - Parameter dataProvider: A data provider to use when registering bundles
    /// - Parameter fileManager: A file persistence manager
    /// - Parameter documentationCoverageOptions: Indicates whether or not to generate coverage output and at what level.
    /// - Parameter diagnosticLevel: The level above which diagnostics will be filtered out. This filter level is inclusive, i.e. if a level of ``DiagnosticSeverity/information`` is specified, diagnostics with a severity up to and including `.information` will be printed.
    /// - Parameter diagnosticEngine: The engine that will collect and emit diagnostics during this action.
    init(
        documentationBundleURL: URL?, outOfProcessResolver: OutOfProcessReferenceResolver?,
        analyze: Bool, targetDirectory: URL, htmlTemplateDirectory: URL?, emitDigest: Bool,
        currentPlatforms: [String : PlatformVersion]?, buildIndex: Bool = false,
        workspace: DocumentationWorkspace = DocumentationWorkspace(),
        context: DocumentationContext? = nil,
        dataProvider: DocumentationWorkspaceDataProvider? = nil,
        fileManager: FileManagerProtocol = FileManager.default,
        temporaryDirectory: URL,
        documentationCoverageOptions: DocumentationCoverageOptions = .noCoverage,
        bundleDiscoveryOptions: BundleDiscoveryOptions = .init(),
        diagnosticLevel: String? = nil,
        diagnosticEngine: DiagnosticEngine? = nil,
        diagnosticFilePath: URL? = nil,
        formatConsoleOutputForTools: Bool = false,
        inheritDocs: Bool = false,
        treatWarningsAsErrors: Bool = false,
        experimentalEnableCustomTemplates: Bool = false,
        experimentalModifyCatalogWithGeneratedCuration: Bool = false,
        transformForStaticHosting: Bool = false,
        allowArbitraryCatalogDirectories: Bool = false,
        hostingBasePath: String? = nil,
        sourceRepository: SourceRepository? = nil,
        dependencies: [URL] = []
    ) throws
    {
        self.rootURL = documentationBundleURL
        self.outOfProcessResolver = outOfProcessResolver
        self.analyze = analyze
        self.targetDirectory = targetDirectory
        self.htmlTemplateDirectory = htmlTemplateDirectory
        self.emitDigest = emitDigest
        self.buildLMDBIndex = buildIndex
        self.workspace = workspace
        self.injectedDataProvider = dataProvider
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.documentationCoverageOptions = documentationCoverageOptions
        self.transformForStaticHosting = transformForStaticHosting
        self.hostingBasePath = hostingBasePath
        self.sourceRepository = sourceRepository
        
        let filterLevel: DiagnosticSeverity
        if analyze {
            filterLevel = .information
        } else {
            filterLevel = DiagnosticSeverity(diagnosticLevel) ?? .warning
        }
        
        let formattingOptions: DiagnosticFormattingOptions
        if formatConsoleOutputForTools || diagnosticFilePath != nil {
            formattingOptions = [.formatConsoleOutputForTools]
        } else {
            formattingOptions = []
        }
        self.diagnosticWriterOptions = (
            formattingOptions,
            documentationBundleURL ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
        )
        
        self.inheritDocs = inheritDocs
        self.treatWarningsAsErrors = treatWarningsAsErrors

        self.experimentalEnableCustomTemplates = experimentalEnableCustomTemplates
        self.experimentalModifyCatalogWithGeneratedCuration = experimentalModifyCatalogWithGeneratedCuration
        
        let engine = diagnosticEngine ?? DiagnosticEngine(treatWarningsAsErrors: treatWarningsAsErrors)
        engine.filterLevel = filterLevel
        if let diagnosticFilePath = diagnosticFilePath {
            engine.add(DiagnosticFileWriter(outputPath: diagnosticFilePath))
        }
        
        self.diagnosticEngine = engine
        self.context = try context ?? DocumentationContext(dataProvider: workspace, diagnosticEngine: engine)
        self.diagnosticLevel = filterLevel
        self.context.externalMetadata.diagnosticLevel = self.diagnosticLevel
        self.context.linkResolver.dependencyArchives = dependencies
        
        // Inject current platform versions if provided
        if let currentPlatforms = currentPlatforms {
            self.context.externalMetadata.currentPlatforms = currentPlatforms
        }

        // Inject user-set flags.
        self.context.externalMetadata.inheritDocs = inheritDocs
        
        switch documentationCoverageOptions.level {
        case .detailed, .brief:
            self.context.shouldStoreManuallyCuratedReferences = true
        case .none:
            break
        }
        
        let dataProvider: DocumentationWorkspaceDataProvider
        if let injectedDataProvider = injectedDataProvider {
            dataProvider = injectedDataProvider
        } else if let rootURL = rootURL {
            dataProvider = try LocalFileSystemDataProvider(
                rootURL: rootURL,
                allowArbitraryCatalogDirectories: allowArbitraryCatalogDirectories
            )
        } else {
            self.context.externalMetadata.isGeneratedBundle = true
            dataProvider = GeneratedDataProvider(symbolGraphDataLoader: { url in
                fileManager.contents(atPath: url.path)
            })
        }
        
        self.converter = DocumentationConverter(
            documentationBundleURL: documentationBundleURL,
            emitDigest: emitDigest,
            documentationCoverageOptions: documentationCoverageOptions,
            currentPlatforms: currentPlatforms,
            workspace: workspace,
            context: self.context,
            dataProvider: dataProvider,
            bundleDiscoveryOptions: bundleDiscoveryOptions,
            sourceRepository: sourceRepository,
            isCancelled: isCancelled,
            diagnosticEngine: self.diagnosticEngine,
            experimentalModifyCatalogWithGeneratedCuration: experimentalModifyCatalogWithGeneratedCuration
        )
    }
    
    /// Initializes the action with the given validated options, creates or uses the given action workspace & context.
    /// - Parameter workspace: A provided documentation workspace. Creates a new empty workspace if value is `nil`
    /// - Parameter context: A provided documentation context. Creates a new empty context in the workspace if value is `nil`
    /// - Parameter dataProvider: A data provider to use when registering bundles
    /// - Parameter documentationCoverageOptions: Indicates whether or not to generate coverage output and at what level.
    /// - Parameter diagnosticLevel: The level above which diagnostics will be filtered out. This filter level is inclusive, i.e. if a level of `DiagnosticSeverity.information` is specified, diagnostics with a severity up to and including `.information` will be printed.
    /// - Parameter diagnosticEngine: The engine that will collect and emit diagnostics during this action.
    public init(
        documentationBundleURL: URL, outOfProcessResolver: OutOfProcessReferenceResolver?,
        analyze: Bool, targetDirectory: URL, htmlTemplateDirectory: URL?, emitDigest: Bool,
        currentPlatforms: [String : PlatformVersion]?, buildIndex: Bool = false,
        workspace: DocumentationWorkspace = DocumentationWorkspace(),
        context: DocumentationContext? = nil,
        dataProvider: DocumentationWorkspaceDataProvider? = nil,
        documentationCoverageOptions: DocumentationCoverageOptions = .noCoverage,
        bundleDiscoveryOptions: BundleDiscoveryOptions = .init(),
        diagnosticLevel: String? = nil,
        diagnosticEngine: DiagnosticEngine? = nil,
        formatConsoleOutputForTools: Bool = false,
        inheritDocs: Bool = false,
        experimentalEnableCustomTemplates: Bool = false,
        experimentalModifyCatalogWithGeneratedCuration: Bool = false,
        transformForStaticHosting: Bool,
        allowArbitraryCatalogDirectories: Bool = false,
        hostingBasePath: String?,
        sourceRepository: SourceRepository? = nil,
        temporaryDirectory: URL,
        dependencies: [URL] = []
    ) throws {
        // Note: This public initializer exists separately from the above internal one
        // because the FileManagerProtocol type we use to enable mocking in tests
        // is internal to this framework.
        //
        // This public initializer just recalls the internal initializer
        // but defaults to `FileManager.default`.
        
        try self.init(
            documentationBundleURL: documentationBundleURL,
            outOfProcessResolver: outOfProcessResolver,
            analyze: analyze,
            targetDirectory: targetDirectory,
            htmlTemplateDirectory: htmlTemplateDirectory,
            emitDigest: emitDigest,
            currentPlatforms: currentPlatforms,
            buildIndex: buildIndex,
            workspace: workspace,
            context: context,
            dataProvider: dataProvider,
            fileManager: FileManager.default,
            temporaryDirectory: temporaryDirectory,
            documentationCoverageOptions: documentationCoverageOptions,
            bundleDiscoveryOptions: bundleDiscoveryOptions,
            diagnosticLevel: diagnosticLevel,
            diagnosticEngine: diagnosticEngine,
            formatConsoleOutputForTools: formatConsoleOutputForTools,
            inheritDocs: inheritDocs,
            experimentalEnableCustomTemplates: experimentalEnableCustomTemplates,
            experimentalModifyCatalogWithGeneratedCuration: experimentalModifyCatalogWithGeneratedCuration,
            transformForStaticHosting: transformForStaticHosting,
            allowArbitraryCatalogDirectories: allowArbitraryCatalogDirectories,
            hostingBasePath: hostingBasePath,
            sourceRepository: sourceRepository,
            dependencies: dependencies
        )
    }

    /// `true` if the convert action is cancelled.
    private let isCancelled = Synchronized<Bool>(false)
    
    /// `true` if the convert action is currently running.
    let isPerforming = Synchronized<Bool>(false)
    
    /// A block to execute when conversion has finished.
    /// It's used as a "future" for when the action is cancelled.
    var didPerformFuture: (()->Void)?
    
    /// A block to execute when conversion has started.
    var willPerformFuture: (()->Void)?

    /// Cancels the action.
    ///
    /// The method blocks until the action has completed cancelling.
    mutating func cancel() throws {
        /// If the action is not running, there is nothing to cancel
        guard isPerforming.sync({ $0 }) == true else { return }
        
        /// If the action is already cancelled throw `cancelPending`.
        if isCancelled.sync({ $0 }) == true {
            throw Error.cancelPending
        }

        /// Set the cancelled flag.
        isCancelled.sync({ $0 = true })
        
        /// Wait for the `perform(logHandle:)` method to call `didPerformFuture()`
        let waitGroup = DispatchGroup()
        waitGroup.enter()
        didPerformFuture = {
            waitGroup.leave()
        }
        waitGroup.wait()
    }

    /// Converts each eligible file from the source documentation bundle,
    /// saves the results in the given output alongside the template files.
    mutating public func perform(logHandle: LogHandle) throws -> ActionResult {
        // Add the default diagnostic console writer now that we know what log handle it should write to.
        if !diagnosticEngine.hasConsumer(matching: { $0 is DiagnosticConsoleWriter }) {
            diagnosticEngine.add(
                DiagnosticConsoleWriter(
                    logHandle,
                    formattingOptions: diagnosticWriterOptions.formatting,
                    baseURL: diagnosticWriterOptions.baseURL,
                    fileManager: fileManager
                )
            )
        }
        
        // The converter has already emitted its problems to the diagnostic engine.
        // Track additional problems separately to avoid repeating the converter's problems.
        var postConversionProblems: [Problem] = []
        let totalTimeMetric = benchmark(begin: Benchmark.Duration(id: "convert-total-time"))
        
        // While running this method keep the `isPerforming` flag up.
        isPerforming.sync({ $0 = true })
        willPerformFuture?()
        defer {
            didPerformFuture?()
            isPerforming.sync({ $0 = false })
            diagnosticEngine.flush()
        }
        
        if let outOfProcessResolver = outOfProcessResolver {
            context.externalDocumentationSources[outOfProcessResolver.bundleIdentifier] = outOfProcessResolver
            context.globalExternalSymbolResolver = outOfProcessResolver
        }
        
        let temporaryFolder = try createTempFolder(
            with: htmlTemplateDirectory)
        
        
        defer {
            try? fileManager.removeItem(at: temporaryFolder)
        }

        let indexHTML: URL?
        if let htmlTemplateDirectory = htmlTemplateDirectory {
            let indexHTMLUrl = temporaryFolder.appendingPathComponent(
                HTMLTemplate.indexFileName.rawValue,
                isDirectory: false
            )
            indexHTML = indexHTMLUrl
            
            let customHostingBasePathProvided = !(hostingBasePath?.isEmpty ?? true)
            if customHostingBasePathProvided {
                let data = try StaticHostableTransformer.indexHTMLData(
                    in: htmlTemplateDirectory,
                    with: hostingBasePath,
                    fileManager: fileManager
                )
                
                // A hosting base path was provided which means we need to replace the standard
                // 'index.html' file with the transformed one.
                try fileManager.createFile(at: indexHTMLUrl, contents: data)
            }
            
            let indexHTMLTemplateURL = temporaryFolder.appendingPathComponent(
                HTMLTemplate.templateFileName.rawValue,
                isDirectory: false
            )
            
            // Delete any existing 'index-template.html' file that
            // was copied into the temporary output directory with the
            // HTML template.
            try? fileManager.removeItem(at: indexHTMLTemplateURL)
        } else {
            indexHTML = nil
        }
        
        var coverageAction = CoverageAction(
            documentationCoverageOptions: documentationCoverageOptions,
            workingDirectory: temporaryFolder,
            fileManager: fileManager)

        // An optional indexer, if indexing while converting is enabled.
        var indexer: Indexer? = nil
        
        let bundleIdentifier = converter.firstAvailableBundle()?.identifier
        if let bundleIdentifier = bundleIdentifier {
            // Create an index builder and prepare it to receive nodes.
            indexer = try Indexer(outputURL: temporaryFolder, bundleIdentifier: bundleIdentifier)
        }

        let outputConsumer = ConvertFileWritingConsumer(
            targetFolder: temporaryFolder,
            bundleRootFolder: rootURL,
            fileManager: fileManager,
            context: context,
            indexer: indexer,
            enableCustomTemplates: experimentalEnableCustomTemplates,
            transformForStaticHostingIndexHTML: transformForStaticHosting ? indexHTML : nil,
            bundleIdentifier: bundleIdentifier
        )

        let analysisProblems: [Problem]
        let conversionProblems: [Problem]
        do {
            (analysisProblems, conversionProblems) = try converter.convert(outputConsumer: outputConsumer)
        } catch {
            if emitDigest {
                let problem = Problem(description: (error as? DescribedError)?.errorDescription ?? error.localizedDescription, source: nil)
                try outputConsumer.consume(problems: context.problems + [problem])
                try moveOutput(from: temporaryFolder, to: targetDirectory)
            }
            throw error
        }

        var didEncounterError = analysisProblems.containsErrors || conversionProblems.containsErrors
        let hasTutorial = context.knownPages.contains(where: {
            guard let kind = try? context.entity(with: $0).kind else { return false }
            return kind == .tutorial || kind == .tutorialArticle
        })
        // Warn the user if the catalog is a tutorial but does not contains a table of contents
        // and provide template content to fix this problem.
        if (
            context.rootTechnologies.isEmpty &&
            hasTutorial
        ) {
            let tableOfContentsFilename = CatalogTemplateKind.tutorialTopLevelFilename
            let source = rootURL?.appendingPathComponent(tableOfContentsFilename)
            var replacements = [Replacement]()
            if let tableOfContentsTemplate = CatalogTemplateKind.tutorialTemplateFiles(converter.firstAvailableBundle()?.displayName ?? "Tutorial Name")[tableOfContentsFilename] {
                replacements.append(
                    Replacement(
                        range: .init(line: 1, column: 1, source: source) ..< .init(line: 1, column: 1, source: source),
                        replacement: tableOfContentsTemplate
                    )
                )
            }
            postConversionProblems.append(
                Problem(
                    diagnostic: Diagnostic(
                        source: source,
                        severity: .warning,
                        identifier: "org.swift.docc.MissingTableOfContents",
                        summary: "Missing tutorial table of contents page.",
                        explanation: "`@Tutorial` and `@Article` pages require a `@Tutorials` table of content page to define the documentation hierarchy."
                    ),
                    possibleSolutions: [
                        Solution(
                            summary: "Create a `@Tutorials` table of content page.",
                            replacements: replacements
                        )
                    ]
                )
            )
        }
        
        // If we're building a navigation index, finalize the process and collect encountered problems.
        if let indexer = indexer {
            let finalizeNavigationIndexMetric = benchmark(begin: Benchmark.Duration(id: "finalize-navigation-index"))
            defer {
                benchmark(end: finalizeNavigationIndexMetric)
            }
            
            // Always emit a JSON representation of the index but only emit the LMDB
            // index if the user has explicitly opted in with the `--emit-lmdb-index` flag.
            let indexerProblems = indexer.finalize(emitJSON: true, emitLMDB: buildLMDBIndex)
            postConversionProblems.append(contentsOf: indexerProblems)
        }
        
        // Output to the user the problems encountered during the convert process
        diagnosticEngine.emit(postConversionProblems)

        // Stop the "total time" metric here. The moveOutput time isn't very interesting to include in the benchmark.
        // New tasks and computations should be added above this line so that they're included in the benchmark.
        benchmark(end: totalTimeMetric)
        
        if !didEncounterError {
            let coverageResults = try coverageAction.perform(logHandle: logHandle)
            postConversionProblems.append(contentsOf: coverageResults.problems)
        }
        
        didEncounterError = didEncounterError || postConversionProblems.containsErrors
        
        // We should generally only replace the current build output if we didn't encounter errors
        // during conversion. However, if the `emitDigest` flag is true,
        // we should replace the current output with our digest of problems.
        if !didEncounterError || emitDigest {
            try moveOutput(from: temporaryFolder, to: targetDirectory)
        }

        // Log the output size.
        benchmark(add: Benchmark.ArchiveOutputSize(archiveDirectory: targetDirectory))
        benchmark(
            add: Benchmark.DataDirectoryOutputSize(
                dataDirectory: targetDirectory.appendingPathComponent(
                    NodeURLGenerator.Path.dataFolderName,
                    isDirectory: true
                )
            )
        )
        benchmark(
            add: Benchmark.IndexDirectoryOutputSize(
                indexDirectory: targetDirectory.appendingPathComponent(
                    NodeURLGenerator.Path.indexFolderName,
                    isDirectory: true
                )
            )
        )
        
        if Benchmark.main.isEnabled {
            // Write the benchmark files directly in the target directory.

            let outputConsumer = ConvertFileWritingConsumer(
                targetFolder: targetDirectory,
                bundleRootFolder: rootURL,
                fileManager: fileManager,
                context: context,
                indexer: nil,
                transformForStaticHostingIndexHTML: nil,
                bundleIdentifier: bundleIdentifier
            )

            try outputConsumer.consume(benchmarks: Benchmark.main)
        }

        return ActionResult(didEncounterError: didEncounterError, outputs: [targetDirectory])
    }
    
    func createTempFolder(with templateURL: URL?) throws -> URL {
        return try Self.createUniqueDirectory(inside: temporaryDirectory, template: templateURL, fileManager: fileManager)
    }
    
    func moveOutput(from: URL, to: URL) throws {
        return try Self.moveOutput(from: from, to: to, fileManager: fileManager)
    }
}
