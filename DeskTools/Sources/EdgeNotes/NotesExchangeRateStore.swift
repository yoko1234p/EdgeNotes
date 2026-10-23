import Combine
import DeskCore
import Foundation
import NotesCore

@MainActor final class NotesExchangeRateStore: ObservableObject {
    @Published private(set) var snapshot: NoteExchangeRates?
    @Published private(set) var busy = false
    @Published private(set) var message = L10n.text("匯率未下載；一般計算可離線使用。")
    private let file: URL?
    private var task: Task<Void, Never>?
    init(directory: URL?) {
        file = directory?.appendingPathComponent("exchange-rates.json")
        if let file, let data = try? BoundedFile.read(file, limit: 128_000),
            let saved = try? JSONDecoder().decode(NoteExchangeRates.self, from: data),
            (try? saved.validate()) != nil
        {
            snapshot = saved
            message = L10n.text("ECB 參考匯率 · ") + saved.date
        }
    }
    func refresh() {
        guard !busy else { return }
        busy = true
        message = L10n.text("正在更新 ECB 匯率…")
        task = Task { [weak self] in
            do {
                let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                    response.url?.host == "www.ecb.europa.eu"
                else { throw DeskError.invalid(L10n.text("匯率伺服器暫不可用。")) }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 128_000 else { throw DeskError.invalid(L10n.text("匯率資料超出上限。")) }
                    data.append(byte)
                }
                let next = try NoteExchangeRates.decodeECB(data)
                guard let self, !Task.isCancelled else { return }
                if let file { try BoundedFile.write(JSONEncoder().encode(next), to: file) }
                snapshot = next
                message = L10n.text("ECB 參考匯率 · ") + next.date
            } catch {
                guard let self, !Task.isCancelled else { return }
                message =
                    L10n.text("更新失敗；")
                    + (snapshot.map { L10n.text("沿用 ") + $0.date + L10n.text(" 匯率。") } ?? L10n.text("尚無離線匯率。"))
            }
            self?.busy = false
            self?.task = nil
        }
    }
}
