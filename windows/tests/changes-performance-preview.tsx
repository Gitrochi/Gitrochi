/** The existing real-component selftest blocks processes and network requests in memory. */
import "../src/app/styles/global.css";
import { changesPerformanceSelfTest } from "../src/app/lib/changes-performance-selftest";
const result = await changesPerformanceSelfTest();
const output = document.getElementById("performance-selftest-result")!;
output.dataset.passed = String(result[0]);
output.textContent = result[1];
