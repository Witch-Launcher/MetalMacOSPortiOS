import UIKit
import MetalBridgeKit

final class CompatibilityViewController: UITableViewController {
    private var bridge: MetalBridge?
    private var bridgeError: String?
    private var probe: ProbeReport?
    private var serviceResults: [ServiceProbeResult]?

    private var recordRows: [CompatibilityRecord] {
        CompatibilityManifest.groupedRecords.flatMap { $0.records }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Metal Bridge Lab"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 84
        tableView.tableFooterView = UIView()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Run Probe",
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(runProbe))
        loadBridge()
    }

    private func loadBridge() {
        do {
            let bridge = try MetalBridge()
            self.bridge = bridge
            self.bridgeError = nil
            self.probe = nil
        } catch {
            self.bridge = nil
            self.bridgeError = error.localizedDescription
            self.probe = nil
        }
        tableView.reloadData()
    }

    @objc private func runProbe() {
        guard let bridge = bridge else { return }
        probe = RenderProbe.run(bridge: bridge)
        serviceResults = ServiceProbes.run(device: bridge.device)
        tableView.reloadData()
    }

    private var deviceRows: [(String, String)] {
        guard let bridge = bridge else {
            return [("Bridge status", bridgeError ?? "MetalBridge could not initialize.")]
        }
        let capabilities = bridge.capabilities
        return [
            ("Device", capabilities.deviceName),
            ("Operating system", capabilities.operatingSystem),
            ("GPU families", capabilities.gpuFamilies.isEmpty ? "Not reported" : capabilities.gpuFamilies.joined(separator: ", ")),
            ("A9 baseline", capabilities.supportsA9Baseline ? "Detected" : "Not detected"),
            ("Probe mode", capabilities.probeMode),
            ("Sample counts", capabilities.sampleCounts.map(String.init).joined(separator: ", ")),
            ("Metal 3", capabilities.supportsMetal3 ? "Supported" : "Not supported"),
            ("Metal 4", capabilities.supportsMetal4 ? "Supported" : "Not supported"),
            ("Unified memory", describe(capabilities.hasUnifiedMemory)),
            ("32-bit float filtering", describe(capabilities.supports32BitFloatFiltering)),
            ("BC texture compression", describe(capabilities.supportsBCTextureCompression)),
            ("Max buffer length", "\(capabilities.maxBufferLength) bytes"),
            ("Max threads per threadgroup", capabilities.maxThreadsPerThreadgroup)
        ]
    }

    private var probeRows: [(String, String)] {
        guard bridge != nil else {
            return [("Render probe", "Unavailable until a Metal device is created.")]
        }
        guard let probe = probe else {
            return [("Render probe", "Not run. Tap Run Probe to test the Metal pipeline.")]
        }
        return [("Render probe", "\(probe.passed ? "Passed" : "Failed"). \(probe.detail)")]
    }

    private var serviceRows: [(String, String)] {
        guard let serviceResults = serviceResults else {
            return [("Service probes", "Not run. Tap Run Probe to test the emulation services.")]
        }
        return serviceResults.map { ($0.name, "\($0.passed ? "Passed" : "Failed"). \($0.detail)") }
    }

    private var statusRows: [(String, String)] {
        BridgeStatus.allCases.map { ($0.title, $0.explanation) }
    }

    private func describe<T>(_ result: BridgeResult<T>) -> String {
        switch result {
        case let .native(value):
            return "\(value) (native)"
        case let .converted(value, note):
            return "\(value) (converted: \(note))"
        case let .partial(value, note):
            return "\(value) (partial: \(note))"
        case let .unsupported(reason):
            return "Unsupported: \(reason)"
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        5
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return deviceRows.count
        case 1: return probeRows.count
        case 2: return serviceRows.count
        case 3: return recordRows.count
        default: return statusRows.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Device"
        case 1: return "Render Probe"
        case 2: return "Service Probes"
        case 3: return "Compatibility Inventory"
        default: return "Status Model"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "Cell")
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.selectionStyle = .none
        cell.accessoryType = .none

        switch indexPath.section {
        case 0:
            let row = deviceRows[indexPath.row]
            cell.textLabel?.text = row.0
            cell.detailTextLabel?.text = row.1
        case 1:
            let row = probeRows[indexPath.row]
            cell.textLabel?.text = row.0
            cell.detailTextLabel?.text = row.1
        case 2:
            let row = serviceRows[indexPath.row]
            cell.textLabel?.text = row.0
            cell.detailTextLabel?.text = row.1
        case 3:
            let record = recordRows[indexPath.row]
            cell.textLabel?.text = "\(record.status.title) · \(record.name)"
            cell.detailTextLabel?.text = """
            \(record.group.title)
            macOS \(record.macOSAvailability) · iOS \(record.iOSAvailability)
            \(record.implementation)
            \(record.limitation)
            Source: \(record.sourceHeader)
            """
            cell.accessoryType = record.documentationURL == nil ? .none : .detailButton
        default:
            let row = statusRows[indexPath.row]
            cell.textLabel?.text = row.0
            cell.detailTextLabel?.text = row.1
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard indexPath.section == 3,
              let url = recordRows[indexPath.row].documentationURL else {
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
