//
//  APIModels.swift
//  ListingForge
//
//  DTOs shared across the auth and account endpoints.
//

import Foundation

struct UserDTO: Codable, Identifiable, Hashable {
    let id: String
    let email: String?
}

struct Session: Codable, Hashable {
    let token: String
    let user: UserDTO
}

struct AppleSignInRequest: Encodable {
    let identityToken: String
    let authorizationCode: String?
    let email: String?
    let fullName: String?
}

struct EmailCodeRequest: Encodable {
    let email: String
}

struct EmailVerifyRequest: Encodable {
    let email: String
    let code: String
}

/// Used for endpoints that return no meaningful body.
struct EmptyResponse: Decodable {}
