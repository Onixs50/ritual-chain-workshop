// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;

    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function lockUntil(address) external view returns (uint256);
}

/// @title AIJudge — commit-reveal bounty judge
/// @notice Submissions are hidden behind a hash during the commit phase, so
///         participants cannot read or copy each other's answers. After the
///         commit phase ends, participants reveal their plaintext answer and
///         the contract checks it against the commitment. Only answers that
///         were both committed AND correctly revealed are eligible for AI
///         judging and for winning the bounty.
contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    struct Submission {
        address submitter;
        bytes32 commitment;
        bool revealed;
        string answer;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 commitDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        uint256 revealedCount;
        Submission[] submissions;
        // 0 = no commitment from this address, otherwise (submissionIndex + 1)
        mapping(address => uint256) commitmentIndex;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 commitDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    /// @notice Creates a bounty with a two-phase deadline: a commit window
    ///         followed by a reveal window.
    /// @param commitDeadline Timestamp after which no new commitments are accepted.
    /// @param revealDeadline Timestamp after which no more reveals are accepted
    ///        and judging becomes possible. Must be strictly after commitDeadline.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 commitDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(commitDeadline > block.timestamp, "commit deadline in past");
        require(
            revealDeadline > commitDeadline,
            "reveal deadline must be after commit deadline"
        );

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];

        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.commitDeadline = commitDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            commitDeadline,
            revealDeadline
        );
    }

    /// @notice Submission phase. Participants submit only a commitment hash;
    ///         the plaintext answer stays off-chain and unreadable until reveal.
    /// @param commitment keccak256(abi.encode(answer, salt, msg.sender, bountyId))
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.commitDeadline, "commit phase closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(commitment != bytes32(0), "empty commitment");
        require(
            bounty.commitmentIndex[msg.sender] == 0,
            "already committed to this bounty"
        );
        require(
            bounty.submissions.length < MAX_SUBMISSIONS,
            "too many submissions"
        );

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                revealed: false,
                answer: ""
            })
        );

        uint256 index = bounty.submissions.length - 1;
        bounty.commitmentIndex[msg.sender] = index + 1;

        emit CommitmentSubmitted(bountyId, index, msg.sender, commitment);
    }

    /// @notice Reveal phase. Participants disclose the plaintext answer and the
    ///         salt used in their commitment. The contract recomputes the hash
    ///         and only accepts the answer if it matches what was committed.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.commitDeadline,
            "reveal phase not started"
        );
        require(block.timestamp < bounty.revealDeadline, "reveal phase closed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 storedIndex = bounty.commitmentIndex[msg.sender];
        require(storedIndex != 0, "no commitment found");

        Submission storage submission = bounty.submissions[storedIndex - 1];
        require(!submission.revealed, "already revealed");

        bytes32 computed = keccak256(
            abi.encode(answer, salt, msg.sender, bountyId)
        );
        require(computed == submission.commitment, "commitment mismatch");

        submission.revealed = true;
        submission.answer = answer;
        bounty.revealedCount += 1;

        emit AnswerRevealed(bountyId, storedIndex - 1, msg.sender);
    }

    /// @notice Runs the AI judge over the revealed submissions. Only callable
    ///         by the bounty owner, and only after the reveal window closes,
    ///         so no answer can influence judging while still hidden.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.revealDeadline,
            "reveal phase not closed"
        );
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.revealedCount > 0, "no revealed answers");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /// @notice Pays out the bounty reward. The winner must be a submission
    ///         that was actually revealed and verified — an un-revealed
    ///         commitment can never win or be paid.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");
        require(
            bounty.submissions[winnerIndex].revealed,
            "winner must be a revealed submission"
        );

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // Grouped into a struct (instead of many individual named return values)
    // to avoid a "stack too deep" compiler error.
    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 commitDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        uint256 submissionCount;
        uint256 revealedCount;
        uint256 winnerIndex;
        bytes aiReview;
    }

    function getBounty(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (BountyView memory) {
        Bounty storage bounty = bounties[bountyId];

        return
            BountyView({
                owner: bounty.owner,
                title: bounty.title,
                rubric: bounty.rubric,
                reward: bounty.reward,
                commitDeadline: bounty.commitDeadline,
                revealDeadline: bounty.revealDeadline,
                judged: bounty.judged,
                finalized: bounty.finalized,
                submissionCount: bounty.submissions.length,
                revealedCount: bounty.revealedCount,
                winnerIndex: bounty.winnerIndex,
                aiReview: bounty.aiReview
            });
    }

    /// @notice Returns submission metadata. `answer` is empty string until
    ///         that submitter reveals — the commitment hash is all that is
    ///         visible on-chain before reveal.
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            bool revealed,
            string memory answer
        )
    {
        Bounty storage bounty = bounties[bountyId];

        require(index < bounty.submissions.length, "invalid index");

        Submission storage submission = bounty.submissions[index];

        return (
            submission.submitter,
            submission.commitment,
            submission.revealed,
            submission.answer
        );
    }

    /// @notice Returns only the revealed answers, in submission order, for
    ///         building the batch LLM judging input off-chain.
    function getRevealedSubmissions(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (address[] memory submitters, string[] memory answers)
    {
        Bounty storage bounty = bounties[bountyId];

        submitters = new address[](bounty.revealedCount);
        answers = new string[](bounty.revealedCount);

        uint256 cursor = 0;
        uint256 len = bounty.submissions.length;
        for (uint256 i = 0; i < len; i++) {
            if (bounty.submissions[i].revealed) {
                submitters[cursor] = bounty.submissions[i].submitter;
                answers[cursor] = bounty.submissions[i].answer;
                cursor++;
            }
        }
    }

    /// @notice Helper for the frontend: has `account` already committed to
    ///         this bounty, and if so at what submission index.
    function commitmentOf(
        uint256 bountyId,
        address account
    ) external view bountyExists(bountyId) returns (bool exists, uint256 index) {
        uint256 stored = bounties[bountyId].commitmentIndex[account];
        return (stored != 0, stored == 0 ? 0 : stored - 1);
    }

    /// @notice Pure helper so off-chain code and tests hash the exact same
    ///         way the contract does when building/verifying a commitment.
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(answer, salt, submitter, bountyId));
    }
}
