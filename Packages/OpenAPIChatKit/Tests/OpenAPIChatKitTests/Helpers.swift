import Foundation
import Testing
@testable import OpenAPIChatKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

let petstore3 = try! APISpec(data: fixture("petstore3"), sourceURL: URL(string: "https://petstore3.swagger.io/api/v3/openapi.json"))
let petstore2 = try! APISpec(data: fixture("petstore2"))

let yamlSpec = """
openapi: 3.1.0
info:
  title: Tasks
  version: 2.0
security:
  - bearer: []
servers:
  - url: https://{region}.example.com/v1
    variables:
      region:
        default: eu
paths:
  /projects/{projectId}/tasks:
    parameters:
      - name: projectId
        in: path
        required: true
        schema: { type: integer }
    get:
      operationId: list-tasks
      summary: List tasks in a project
      parameters:
        - name: filter
          in: query
          style: deepObject
          schema:
            type: object
            properties:
              status: { type: string, enum: [open, done] }
        - name: Accept
          in: header
          schema: { type: string }
      security: []
    post:
      summary: Create a task
      requestBody:
        required: true
        content:
          application/json:
            schema:
              allOf:
                - $ref: '#/components/schemas/TaskBase'
                - type: object
                  required: [title]
                  properties:
                    title: { type: string }
                    id: { type: string, readOnly: true }
components:
  securitySchemes:
    bearer: { type: http, scheme: bearer }
    key: { type: apiKey, in: query, name: api_key }
  schemas:
    TaskBase:
      type: object
      properties:
        due: { type: [string, "null"], format: date }
        parent: { $ref: '#/components/schemas/Node' }
        labels: { type: array, items: { type: string } }
        priority:
          oneOf:
            - { type: "null" }
            - { type: integer, minimum: 1, maximum: 5 }
    Node:
      type: object
      properties:
        child: { $ref: '#/components/schemas/Node' }
"""
