import Foundation

/// Task CRUD for the task screen. Item toggles send the full items array —
/// the server's PATCH takes partial Task fields, and items is one field.
extension APIClient {

    private struct TaskListResponse: Decodable {
        let tasks: [OttoTask]
    }

    private struct TaskItemsBody: Encodable {
        let items: [ListItem]
    }

    func listTasks(status: TaskStatus = .active) async throws -> [OttoTask] {
        let data = try await jsonRequest(
            path: "tasks",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "status", value: status.rawValue),
                URLQueryItem(name: "limit", value: "100"),
            ]
        )
        return try decodeBody(TaskListResponse.self, from: data).tasks
    }

    func updateTaskItems(id: String, items: [ListItem]) async throws -> OttoTask {
        let body = try OttoCoding.encoder.encode(TaskItemsBody(items: items))
        let data = try await jsonRequest(path: "tasks/\(id)", method: "PATCH", body: body)
        return try decodeBody(OttoTask.self, from: data)
    }

    func deleteTask(id: String) async throws {
        _ = try await jsonRequest(path: "tasks/\(id)", method: "DELETE")
    }
}

extension APIClient {
    /// A queue-drained capture (share extension, offline note) becomes a
    /// real capture task, no model in the loop.
    func captureTask(_ text: String) async throws {
        struct Body: Encodable {
            struct Trigger: Encodable { let type: String }
            let intent: String
            let title: String
            let items: [String]
            let trigger: Trigger
            let verification: String
            let status: String
        }
        let title = String(text.prefix(200))
        let body: Data
        do {
            body = try OttoCoding.encoder.encode(
                Body(
                    intent: "capture",
                    title: title,
                    items: [],
                    trigger: Body.Trigger(type: "none"),
                    verification: "inline",
                    status: "active"
                )
            )
        } catch {
            throw APIError.decoding(underlying: error)
        }
        _ = try await jsonRequest(path: "tasks", method: "POST", body: body)
    }
}
