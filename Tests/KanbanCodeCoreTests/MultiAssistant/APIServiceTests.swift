import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("APIService Entity")
struct APIServiceTests {

    // MARK: - needsSeparator

    @Test("needsSeparator is false when neither prefix nor model is set")
    func needsSeparatorFalseWhenBare() {
        let service = APIService(name: "Bare", assistant: .claude)
        #expect(service.needsSeparator == false)
    }

    @Test("needsSeparator is true when launcherPrefix is set")
    func needsSeparatorTrueWithPrefix() {
        let service = APIService(name: "Ollama", assistant: .claude, launcherPrefix: "ollama launch")
        #expect(service.needsSeparator == true)
    }

    @Test("needsSeparator is true when modelFlag is set")
    func needsSeparatorTrueWithModel() {
        let service = APIService(name: "Model", assistant: .claude, modelFlag: "claude-opus-4-5")
        #expect(service.needsSeparator == true)
    }

    @Test("needsSeparator is true when both prefix and model are set")
    func needsSeparatorTrueWithBoth() {
        let service = APIService(
            name: "Ollama",
            assistant: .claude,
            launcherPrefix: "ollama launch",
            modelFlag: "qwen3-coder-next:cloud"
        )
        #expect(service.needsSeparator == true)
    }

    // MARK: - Codable

    @Test("APIService Codable round-trip — full fields")
    func codableRoundTripFull() throws {
        let service = APIService(
            id: "svc-001",
            name: "Ollama Local",
            assistant: .claude,
            launcherPrefix: "ollama launch",
            modelFlag: "qwen3-coder-next:cloud",
            baseURL: "http://localhost:11434/v1"
        )
        let data = try JSONEncoder().encode(service)
        let decoded = try JSONDecoder().decode(APIService.self, from: data)
        #expect(decoded.id == "svc-001")
        #expect(decoded.name == "Ollama Local")
        #expect(decoded.assistant == .claude)
        #expect(decoded.launcherPrefix == "ollama launch")
        #expect(decoded.modelFlag == "qwen3-coder-next:cloud")
        #expect(decoded.baseURL == "http://localhost:11434/v1")
    }

    @Test("APIService Codable round-trip — optional fields nil")
    func codableRoundTripMinimal() throws {
        let service = APIService(name: "Minimal", assistant: .gemini)
        let data = try JSONEncoder().encode(service)
        let decoded = try JSONDecoder().decode(APIService.self, from: data)
        #expect(decoded.name == "Minimal")
        #expect(decoded.assistant == .gemini)
        #expect(decoded.launcherPrefix == nil)
        #expect(decoded.modelFlag == nil)
        #expect(decoded.baseURL == nil)
        #expect(decoded.needsSeparator == false)
    }

    @Test("APIService Equatable")
    func equatable() {
        let a = APIService(id: "x", name: "A", assistant: .claude)
        let b = APIService(id: "x", name: "A", assistant: .claude)
        let c = APIService(id: "y", name: "A", assistant: .claude)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Edit-in-place logic

    @Test("Editing a service preserves its ID")
    func editPreservesId() {
        let original = APIService(id: "svc-42", name: "Old Name", assistant: .claude, modelFlag: "old-model")
        let edited = APIService(
            id: original.id,
            name: "New Name",
            assistant: original.assistant,
            launcherPrefix: "ollama launch",
            modelFlag: "new-model"
        )
        #expect(edited.id == original.id)
        #expect(edited.name == "New Name")
        #expect(edited.modelFlag == "new-model")
        #expect(edited.launcherPrefix == "ollama launch")
    }

    @Test("Update-in-place replaces the matching entry and leaves others intact")
    func updateInPlaceByIndex() {
        var services = [
            APIService(id: "svc-1", name: "First", assistant: .claude),
            APIService(id: "svc-2", name: "Target", assistant: .claude, modelFlag: "old"),
            APIService(id: "svc-3", name: "Third", assistant: .claude),
        ]
        let updated = APIService(id: "svc-2", name: "Updated", assistant: .claude, modelFlag: "new")
        if let idx = services.firstIndex(where: { $0.id == updated.id }) {
            services[idx] = updated
        }
        #expect(services.count == 3)
        #expect(services[0].name == "First")
        #expect(services[1].name == "Updated")
        #expect(services[1].modelFlag == "new")
        #expect(services[2].name == "Third")
    }

    @Test("Editing a service updates the command it produces")
    func editedServiceUpdatesCommand() {
        let original = APIService(id: "svc-1", name: "Ollama", assistant: .claude, modelFlag: "qwen3")
        let originalCmd = CodingAssistant.claude.launchCommand(skipPermissions: true, worktreeName: nil, service: original)
        #expect(originalCmd == "claude --model qwen3 -- --dangerously-skip-permissions")

        let edited = APIService(id: "svc-1", name: "Ollama", assistant: .claude, launcherPrefix: "ollama launch", modelFlag: "qwen3-v2")
        let editedCmd = CodingAssistant.claude.launchCommand(skipPermissions: true, worktreeName: nil, service: edited)
        #expect(editedCmd == "ollama launch claude --model qwen3-v2 -- --dangerously-skip-permissions")
    }

    @Test("Deleting the default service clears the default ID mapping")
    func deleteDefaultClearsMapping() {
        var services = [
            APIService(id: "svc-1", name: "Ollama", assistant: .claude),
        ]
        var defaultIds: [String: String] = ["claude": "svc-1"]
        let toDelete = services[0]

        services.removeAll { $0.id == toDelete.id }
        if defaultIds["claude"] == toDelete.id {
            defaultIds.removeValue(forKey: "claude")
        }

        #expect(services.isEmpty)
        #expect(defaultIds["claude"] == nil)
    }
}
