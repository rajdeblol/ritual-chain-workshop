import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("CommitRevealAIJudgeModule", (m) => {
  const judge = m.contract("CommitRevealAIJudge");
  return { judge };
});
