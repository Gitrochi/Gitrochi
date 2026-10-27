import { describe, expect, it } from "vitest";
import { workspaceFixtureProjectQuery } from "../src/app/lib/workspace-panels-fixture";
const url = "https://api.github.com/graphql";
const query = "query($owner:String!,$cursor:String){user(login:$owner){projectsV2(first:30,after:$cursor){nodes{id title} pageInfo{hasNextPage endCursor}}}}";
const body = JSON.stringify({ query, variables: { owner: "fixture", cursor: null } });
describe("workspace panel fixture project reads", () => {
  it("recognizes the actual personal-project query and its owner", () => {
    expect(workspaceFixtureProjectQuery("POST", url, body)).toEqual({ owner: "fixture" });
  });
  it("keeps GraphQL mutations in the unexpected-write guard", () => {
    expect(workspaceFixtureProjectQuery("POST", url, JSON.stringify({ query: query.replace("query(", "mutation("), variables: { owner: "fixture" } }))).toBeNull();
    expect(workspaceFixtureProjectQuery("POST", url, JSON.stringify({ query: `${query}\nmutation { deleteProjectV2(input:{projectId:\"P\"}) { deletedProjectV2Id } }`, variables: { owner: "fixture" } }))).toBeNull();
  });
  it("rejects unrelated operations and malformed requests", () => {
    expect(workspaceFixtureProjectQuery("GET", url, body)).toBeNull();
    expect(workspaceFixtureProjectQuery("POST", "https://example.com/graphql", body)).toBeNull();
    expect(workspaceFixtureProjectQuery("POST", "https://api.github.com/repos/fixture/repo/issues", body)).toBeNull();
    expect(workspaceFixtureProjectQuery("POST", url, "{")).toBeNull();
    expect(workspaceFixtureProjectQuery("POST", url, JSON.stringify({ query: "query($id:ID!){node(id:$id){id}}", variables: { owner: "fixture" } }))).toBeNull();
    expect(workspaceFixtureProjectQuery("POST", url, JSON.stringify({ query, variables: {} }))).toBeNull();
  });
});
