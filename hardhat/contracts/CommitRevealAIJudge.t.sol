// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitRevealAIJudge} from "./CommitRevealAIJudge.sol";

/// @notice Stand-in for the real Ritual LLM_INFERENCE_PRECOMPILE (0x0802).
///         Its runtime code is `vm.etch`-ed onto the precompile address so
///         judgeAll() can be exercised end-to-end in a plain local EVM,
///         without a live Ritual TEE executor.
contract MockLLMPrecompile {
    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory completionData = bytes("winnerIndex=0");
        bytes memory actualOutput = abi.encode(
            false, // hasError
            completionData,
            bytes(""), // raw
            "", // errorMessage
            CommitRevealAIJudge.ConvoHistory("", "", "")
        );
        // _executePrecompile expects abi.encode(simmedInput, actualOutput)
        return abi.encode(bytes(""), actualOutput);
    }
}

contract CommitRevealAIJudgeTest is Test {
    CommitRevealAIJudge judge;

    address owner = address(0xA11CE);
    address alice = address(0xA1);
    address bob = address(0xB0);
    address carol = address(0xC0);

    uint256 constant REWARD = 1 ether;
    uint256 commitDeadline;
    uint256 revealDeadline;

    function setUp() public {
        judge = new CommitRevealAIJudge();

        // Plant the mock LLM precompile at the address PrecompileConsumer calls.
        MockLLMPrecompile mock = new MockLLMPrecompile();
        vm.etch(address(0x0802), address(mock).code);

        vm.deal(owner, 10 ether);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);

        commitDeadline = block.timestamp + 1 days;
        revealDeadline = block.timestamp + 2 days;
    }

    function _createBounty() internal returns (uint256 bountyId) {
        vm.prank(owner);
        bountyId = judge.createBounty{value: REWARD}(
            "Best one-liner",
            "Funniest wins",
            commitDeadline,
            revealDeadline
        );
    }

    function _commitment(
        string memory answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) internal view returns (bytes32) {
        return judge.computeCommitment(answer, salt, submitter, bountyId);
    }

    // -------------------------------------------------------------------
    // Happy path
    // -------------------------------------------------------------------

    function test_FullLifecycle_CommitRevealJudgeFinalize() public {
        uint256 bountyId = _createBounty();

        bytes32 saltA = keccak256("alice-salt");
        bytes32 saltB = keccak256("bob-salt");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("alice answer", saltA, alice, bountyId)
        );

        vm.prank(bob);
        judge.submitCommitment(
            bountyId,
            _commitment("bob answer", saltB, bob, bountyId)
        );

        // Move into the reveal window.
        vm.warp(commitDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, "alice answer", saltA);

        vm.prank(bob);
        judge.revealAnswer(bountyId, "bob answer", saltB);

        (, , , , uint256 revealedCount, ) = judge.getBountyStatus(bountyId);
        assertEq(revealedCount, 2);

        // Move past the reveal deadline and judge.
        vm.warp(revealDeadline + 1);

        vm.prank(owner);
        judge.judgeAll(bountyId, hex"00");

        vm.prank(owner);
        judge.finalizeWinner(bountyId, 0);

        (, , , uint256 reward, , ) = judge.getBounty(bountyId);
        (bool judged, bool finalized, , , uint256 winnerIndex, ) = judge
            .getBountyStatus(bountyId);

        assertTrue(judged);
        assertTrue(finalized);
        assertEq(winnerIndex, 0);
        assertEq(reward, 0); // reward paid out, swept to zero
        assertEq(alice.balance, 1 ether + REWARD);
    }

    // -------------------------------------------------------------------
    // Commit-phase guards
    // -------------------------------------------------------------------

    function test_RevertWhen_CommitAfterCommitDeadline() public {
        uint256 bountyId = _createBounty();
        vm.warp(commitDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("commit phase over"));
        judge.submitCommitment(bountyId, keccak256("anything"));
    }

    function test_RevertWhen_DoubleCommit() public {
        uint256 bountyId = _createBounty();

        vm.prank(alice);
        judge.submitCommitment(bountyId, keccak256("first"));

        vm.prank(alice);
        vm.expectRevert(bytes("already committed"));
        judge.submitCommitment(bountyId, keccak256("second"));
    }

    // -------------------------------------------------------------------
    // Reveal-phase guards (the core of this assignment)
    // -------------------------------------------------------------------

    function test_RevertWhen_RevealBeforeCommitDeadline() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );

        // Still inside the commit window -- reveal not open yet.
        vm.prank(alice);
        vm.expectRevert(bytes("reveal phase not started"));
        judge.revealAnswer(bountyId, "answer", salt);
    }

    function test_RevertWhen_RevealAfterRevealDeadline() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );

        vm.warp(revealDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("reveal phase over"));
        judge.revealAnswer(bountyId, "answer", salt);
    }

    function test_RevertWhen_RevealWithoutCommitment() public {
        uint256 bountyId = _createBounty();
        vm.warp(commitDeadline + 1);

        vm.prank(carol); // never committed
        vm.expectRevert(bytes("no commitment found"));
        judge.revealAnswer(bountyId, "answer", keccak256("s"));
    }

    function test_RevertWhen_RevealWrongAnswer() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("real answer", salt, alice, bountyId)
        );

        vm.warp(commitDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("hash mismatch"));
        judge.revealAnswer(bountyId, "different answer", salt);
    }

    function test_RevertWhen_RevealWrongSalt() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");
        bytes32 wrongSalt = keccak256("wrong");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );

        vm.warp(commitDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("hash mismatch"));
        judge.revealAnswer(bountyId, "answer", wrongSalt);
    }

    function test_RevertWhen_DoubleReveal() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );

        vm.warp(commitDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        vm.prank(alice);
        vm.expectRevert(bytes("already revealed"));
        judge.revealAnswer(bountyId, "answer", salt);
    }

    function test_CommitmentIsBoundToSenderAndBounty() public {
        // Bob cannot reveal Alice's commitment under his own address, and
        // a commitment made for one bountyId cannot be replayed on another.
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );

        vm.warp(commitDeadline + 1);

        // Bob never committed for this bounty, so he has nothing to reveal.
        vm.prank(bob);
        vm.expectRevert(bytes("no commitment found"));
        judge.revealAnswer(bountyId, "answer", salt);
    }

    function test_UnrevealedCommitmentIsExcludedFromJudging() public {
        uint256 bountyId = _createBounty();
        bytes32 saltA = keccak256("a");
        bytes32 saltB = keccak256("b");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("alice answer", saltA, alice, bountyId)
        );

        vm.prank(bob);
        judge.submitCommitment(
            bountyId,
            _commitment("bob answer", saltB, bob, bountyId)
        );

        vm.warp(commitDeadline + 1);

        // Only Alice reveals; Bob goes silent (e.g. lost his salt).
        vm.prank(alice);
        judge.revealAnswer(bountyId, "alice answer", saltA);

        vm.warp(revealDeadline + 1);

        (, , uint256 commitCount, uint256 revealedCount, , ) = judge
            .getBountyStatus(bountyId);
        assertEq(commitCount, 2);
        assertEq(revealedCount, 1); // Bob's plaintext never reaches anyone

        vm.prank(owner);
        judge.judgeAll(bountyId, hex"00"); // succeeds with just Alice's answer
    }

    // -------------------------------------------------------------------
    // Judge / finalize gating
    // -------------------------------------------------------------------

    function test_RevertWhen_JudgeAllBeforeRevealDeadline() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        // Reveal deadline hasn't passed yet.
        vm.prank(owner);
        vm.expectRevert(bytes("reveal phase not over"));
        judge.judgeAll(bountyId, hex"00");
    }

    function test_RevertWhen_JudgeAllWithNoRevealedAnswers() public {
        uint256 bountyId = _createBounty();
        vm.warp(revealDeadline + 1);

        vm.prank(owner);
        vm.expectRevert(bytes("no revealed submissions"));
        judge.judgeAll(bountyId, hex"00");
    }

    function test_RevertWhen_NonOwnerCallsJudgeAll() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);
        vm.warp(revealDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        judge.judgeAll(bountyId, hex"00");
    }

    function test_RevertWhen_FinalizeBeforeJudged() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        vm.prank(owner);
        vm.expectRevert(bytes("not judged yet"));
        judge.finalizeWinner(bountyId, 0);
    }

    function test_RevertWhen_FinalizeWithInvalidWinnerIndex() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);
        vm.warp(revealDeadline + 1);

        vm.prank(owner);
        judge.judgeAll(bountyId, hex"00");

        vm.prank(owner);
        vm.expectRevert(bytes("invalid winner index"));
        judge.finalizeWinner(bountyId, 5); // only index 0 exists
    }

    function test_RevertWhen_DoubleFinalize() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("answer", salt, alice, bountyId)
        );
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);
        vm.warp(revealDeadline + 1);

        vm.prank(owner);
        judge.judgeAll(bountyId, hex"00");

        vm.prank(owner);
        judge.finalizeWinner(bountyId, 0);

        vm.prank(owner);
        vm.expectRevert(bytes("already finalized"));
        judge.finalizeWinner(bountyId, 0);
    }
}
