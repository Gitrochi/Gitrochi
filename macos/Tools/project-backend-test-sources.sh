#!/usr/bin/env bash
# Production backend dependencies shared by standalone HostingHub test harnesses.
PROJECT_BACKEND_TEST_SOURCES=(
    "$ROOT/Sources/Services/OrganizationManagement.swift"
    "$ROOT/Sources/Services/OrganizationPermissions.swift"
    "$ROOT/Sources/Core/ProjectSchedule.swift"
    "$ROOT/Sources/Core/LocalProjectDocument.swift"
    "$ROOT/Sources/Services/LocalProjectPersistence.swift"
    "$ROOT/Sources/Services/LocalProjects.swift"
    "$ROOT/Sources/Services/ProjectBackend.swift"
)
