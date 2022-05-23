//SPDX-License-Identifier: MIT
// @cryptopunkart painting your punks
pragma solidity ^0.8.12;

import "hardhat/console.sol";

/*

The Rules

1. Punk owner commissions the painter their punk painted (a job). A commission gets sent to escrow.
2. Painter finishes the painting, and uploads the image, sets the URL, marking the job
"Complete" and available to be accepted by the commissioner.
3. Commissioner accepts the job, receives the NFT, commission is released from escrow and sent to painter
4. Dispute: If not accepted in step 3, the CEO would need to resolve the dispute.
The CEO will either accept the job, or refund the job. CEO will receive a 10% fee deducted from the escrow.
5. Up to 20 jobs can be opened at the same time

*/

contract Painter {

    address public curator;                                    // the curator
    string private baseURI;
    uint256 private immutable max;                             // total supply (10,000)
    uint256 public price;
    address constant studio = 0x0101010101010101010101010101010101010101; // paintings in progress are held by studio
    ICryptoPunks immutable public punks;
    ICigtoken immutable public cig;
    struct Painting {
        State state;
        uint256 withheld;
        uint256 updatedAt;
        uint256 punkID;
        bytes32 hash;
    }
    enum State {
        Null,         // Initial
        Commissioned, // punk holder commissions painting (nft is minted)
        Completed,    // painter completed the job (awaiting to be accepted)
        Accepted,     // punk accepted completed job (nft transferred to owner, payment released to artist)
        Disputed,     // punk disputed completed job, can go to Completed or Initial (with refund)
        Refunded
    }
    uint256[20] public jobs;                                          // jobs that are not completed yet (punk ids)
    mapping(uint256 => Painting) public paintings;                    // punk id to painting
    mapping(address => uint256) private balances;                     // counts of ownership
    mapping(uint256  => address) private ownership;
    mapping(uint256  => address) private approval;
    mapping(address => mapping(address => bool)) private approvalAll; // operator approvals

    event Complete(uint256 punkID);
    event Accepted(uint256 punkID);
    event Refund(uint256 punkID);
    event Disputed(uint256 punkID);
    /**
     * Mint is fired when a new token is minted
     */
    event Mint(address owner, uint256 tokenId);
    /**
     * @dev Burn is fired when a token is burned
     */
    event Burn(address owner, uint256 tokenId);

    /**
     * @dev OwnershipTransferred is fired when a curator is changed
     */
    event OwnershipTransferred(address previousOwner, address newOwner);
    /**
     * @dev BaseURI is fired when the baseURI changed (set by the Curator)
     */
    event BaseURI(string);
    /**
    * @dev Painetr constructor
    * @param _punks address of the cryptopunks contract
    * @param _max max supply of the NFT collection
    */
    constructor(
        address _punks,    // eg. 0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb
        uint256 _max,
        uint256 _price,
        address _cig       // 0xcb56b52316041a62b6b5d0583dce4a8ae7a3c629
    ) {
        curator = msg.sender;
        punks = ICryptoPunks(_punks);
        max = _max;
        price = _price;
        balances[address(this)] = _max; // track how many haven't been minted
        cig = ICigtoken(_cig);
    }

    modifier onlyCurator {
        require(
            msg.sender == curator,
            "only curator can call this"
        );
        _;
    }

    /**
    * @dev regulators are not needed - smart contracts regulate themselves
    */
    modifier regulated(address _to) {
        require(
            _to != studio,
            "cannot send to dead address"
        );
        require(
            _to != address(this),
            "cannot send to self"
        );
        require(
            _to != address(0),
            "cannot send to 0x"
        );
        _;
    }

    /**
    * @dev setPrice allows the curator to set the price
    * @param _p the price
    */
    function setPrice(uint256 _p) external onlyCurator {
        price = _p;
    }

    /**
    * @dev getStats helps to fetch some stats for the UI in a single web3 call
    * @param _user the address to return the report for
    * @return uint256[10] the stats
    */
    function getStats(address _user) external view returns(uint256[] memory) {
        uint[] memory ret = new uint[](10);
        ret[5] = balanceOf(_user);                         // how many _user has
        ret[7] = balanceOf(address(this));                 // how many NFTs to be upgraded
        return ret;
    }

    /**
    * @dev commission mints a token and assigns to the curator. Think of it as an empty canvas
    */
    function commission(uint256 _punkID, uint256 _jobIndex) external {
        require (punks.punkIndexToAddress(_punkID) == msg.sender, "must own punk");
        Painting storage p = paintings[_punkID];
        require(p.state == State.Null, "painting already commissioned");
        uint256 punkID = jobs[_jobIndex];
        require (punkID == 0, "job must be empty");
        jobs[_jobIndex] = _punkID+1; // punkIDs on job index start from 1
        cig.transferFrom(msg.sender, address(this), price);
        p.state = State.Commissioned;
        p.withheld = price;
        p.punkID = _punkID;
        p.updatedAt = block.timestamp;
        _transfer(address(this), studio, _punkID);
        emit Mint(studio, _punkID);
    }

    /**
    * @dev artists marks the Commissioned painting completed
    */
    function complete(uint256 _punkID, uint256 _jobIndex, bytes32 _hash) external onlyCurator {
        Painting storage p = paintings[_punkID];
        require(jobs[_jobIndex] != 0, "no job found");
        require(jobs[_jobIndex]-1 == _punkID, "job not match punk");
        require(p.state == State.Commissioned, "painting not commissioned");
        p.state = State.Completed;
        p.updatedAt = block.timestamp;
        p.hash = _hash;
        emit Complete(_punkID);
    }

    /**
    * @dev owner accepts completed painting
    */
    function accept(uint256 _punkID, uint256 _jobIndex) external  {
        require (punks.punkIndexToAddress(_punkID) == msg.sender, "must own punk");
        require(jobs[_jobIndex] != 0, "no job found");
        require(jobs[_jobIndex]-1 == _punkID, "job not match punk");
        Painting storage p = paintings[_punkID];
        require(p.state == State.Completed, "painting not completed");
        _accept(_punkID, _jobIndex, p, 0, address(0), msg.sender);
    }

    function _accept(
        uint256 _punkID,
        uint256 _jobIndex,
        Painting storage _p,
        uint256 ceoSplit,
        address ceo,
        address commissioner
    ) internal {

        _p.state = State.Accepted;
        _p.updatedAt = block.timestamp;
        uint256 pay = _p.withheld;
        if (ceoSplit > 0) {
            uint256 cut = pay / ceoSplit;
            cig.transfer(ceo, cut);
            pay = pay - cut;
        }
        cig.transfer(curator, pay);               // release funds to artist
        _transfer(studio, commissioner, _punkID); // transfer nft to commissioner
        jobs[_jobIndex] = 0;                      // remove the job
        emit Accepted(_punkID);
    }

    function acceptByCEO(
        uint256 _punkID, uint256 _jobIndex
    ) external {
        // only CEO
        address ceo = cig.The_CEO();
        require(msg.sender == ceo, "must be ceo");
        require (block.number - cig.taxBurnBlock() > 90, "90 blocks min");
        require(jobs[_jobIndex] != 0, "no job found");
        require(jobs[_jobIndex]-1 == _punkID, "job not match punk");
        Painting storage p = paintings[_punkID];
        require(p.state == State.Disputed, "painting not disputed");
        _accept(_punkID, _jobIndex, p, 10, ceo, punks.punkIndexToAddress(_punkID)); // 10% to CEO
    }

    /**
    * @dev owner disputes completed painting
    */
    function dispute(uint256 _punkID, uint256 _jobIndex) external  {
        require (punks.punkIndexToAddress(_punkID) == msg.sender, "must own punk");
        require(jobs[_jobIndex] != 0, "no job found");
        require(jobs[_jobIndex]-1 == _punkID, "job not match punk");
        Painting storage p = paintings[_punkID];
        require(p.state == State.Completed, "painting not completed");
        p.state = State.Disputed;
        p.updatedAt = block.timestamp;
        emit Disputed(_punkID);
    }



    function refundByCEO(uint256 _punkID, uint256 _jobIndex) external {
        address ceo = cig.The_CEO();
        require(msg.sender == ceo, "must be ceo");
        require (block.number - cig.taxBurnBlock() > 90, "90 blocks min");

        require(jobs[_jobIndex] != 0, "no job found");
        require(jobs[_jobIndex]-1 == _punkID, "job not match punk");
        Painting storage p = paintings[_punkID];
        require(p.state == State.Disputed, "painting not disputed");
        //_p.state = State.Accepted;
        p.updatedAt = block.timestamp;
        uint256 pay = p.withheld;
        uint256 cut = pay / 10;
        cig.transfer(ceo, cut);                              // pay 10% to ceo
        pay = pay - cut;
        cig.transfer(punks.punkIndexToAddress(_punkID), pay);// refund to artist
        _transfer(
            studio,
            address(this),
            _punkID
        );                                        // transfer nft to contract
        jobs[_jobIndex] = 0;                      // remove the job
        p.state = State.Refunded;
        emit Refund(_punkID);
    }


    /**
    * TODO
    * @dev burn burns a token
    */
    function burn(uint256 id) external {
        require (msg.sender == ownership[id], "only owner can burn");
        emit Burn(msg.sender, id);
    }

    /**
    * @dev setCurator sets the curator address
    */
    function setCurator(address _curator) external onlyCurator {
        _transferOwnership(_curator);
    }

    /**
    * owner is part of the Ownable interface
    */
    function owner() external view returns (address) {
        return curator;
    }
    /**
    * renounceOwnership is part of the Ownable interface
    */
    function renounceOwnership() external  {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal {
        address oldOwner = curator;
        curator = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /**
    * @dev setBaseURI sets the baseURI value
    */
    function setBaseURI(string memory _uri) external onlyCurator {
        baseURI = _uri;
        emit BaseURI(_uri);
    }

    /***
    * ERC721 stuff
    */

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @dev Approval is fired when `owner` enables `approved` to manage the `tokenId` token.
     */
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /**
     * @dev ApprovalForAll is fired when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
     */
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /// @notice Count NFTs tracked by this contract
    /// @return A count of valid NFTs tracked by this contract, where each one of
    ///  them has an assigned and queryable owner not equal to the zero address
    function totalSupply() external view returns (uint256) {
        return max;
    }

    /// @notice Enumerate valid NFTs
    /// @dev Throws if `_index` >= `totalSupply()`.
    /// @param _index A counter less than `totalSupply()`
    /// @return The token identifier for the `_index`th NFT,
    ///  (sort order not specified)
    function tokenByIndex(uint256 _index) external view returns (uint256) {
        require (_index < max, "index out of range");
        return _index;
    }

    /// @notice Enumerate NFTs assigned to an owner
    /// @dev Throws if `_index` >= `balanceOf(_owner)` or if
    ///  `_owner` is the zero address, representing invalid NFTs.
    /// @param _owner An address where we are interested in NFTs owned by them
    /// @param _index A counter less than `balanceOf(_owner)`
    /// @return The token identifier for the `_index`th NFT assigned to `_owner`,
    ///   (sort order not specified)
    function tokenOfOwnerByIndex(address _owner, uint256 _index) external view returns (uint256) {
        require (_index < max, "index out of range");
        require (_owner != address(0), "address invalid");
        require (ownership[_index] != address(0), "token not assigned");
        return _index;
    }

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address _holder) public view returns (uint256) {
        require (_holder != address(0));
        return balances[_holder];
    }

    function name() public pure returns (string memory) {
        return "CryptoPunkArt";
    }

    function symbol() public pure returns (string memory) {
        return "CPArt";
    }

    /**
     * @dev Returns the Uniform Resource Identifier (URI) for `tokenId` token.
     */
    function tokenURI(uint256 _tokenId) public view returns (string memory) {
        require (_tokenId < max, "index out of range");
        string memory _baseURI = baseURI;
        uint256 num = _tokenId % 100;
        return bytes(_baseURI).length > 0
        ? string(abi.encodePacked(_baseURI, toString(_tokenId/100), "/", toString(num), ".json"))
        : '';
    }

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint256 _tokenId) public view returns (address) {
        require (_tokenId < max, "index out of range");
        address holder = ownership[_tokenId];
        require (holder != address(0), "not minted.");
        return holder;
    }

    /**
    * @dev Throws unless `msg.sender` is the current owner, an authorized
    *  operator, or the approved address for this NFT. Throws if `_from` is
    *  not the current owner. Throws if `_to` is the zero address. Throws if
    *  `_tokenId` is not a valid NFT.
    * @param _from The current owner of the NFT
    * @param _to The new owner
    * @param _tokenId The NFT to transfer
    */
    function safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes memory _data) external regulated(_to) {
        require (_tokenId < max, "index out of range");
        address o = ownership[_tokenId];
        require (o == _from, "_from must be owner");
        address a = approval[_tokenId];
        require (o == msg.sender || (a == msg.sender) || (approvalAll[o][msg.sender]), "not permitted");
        _transfer(_from, _to, _tokenId);
        if (a != address(0)) {
            approval[_tokenId] = address(0); // clear previous approval
            emit Approval(msg.sender, address(0), _tokenId);
        }
        require(_checkOnERC721Received(_from, _to, _tokenId, _data), "ERC721: transfer to non ERC721Receiver implementer");
    }

    /**
    * @dev Throws unless `msg.sender` is the current owner, an authorized
    *  operator, or the approved address for this NFT. Throws if `_from` is
    *  not the current owner. Throws if `_to` is the zero address. Throws if
    *  `_tokenId` is not a valid NFT.
    * @param _from The current owner of the NFT
    * @param _to The new owner
    * @param _tokenId The NFT to transfer
    */
    function safeTransferFrom(address _from, address _to, uint256 _tokenId) external regulated(_to) {
        require (_tokenId < max, "index out of range");
        address o = ownership[_tokenId];
        require (o == _from, "_from must be owner");
        address a = approval[_tokenId];
        require (o == msg.sender || (a == msg.sender) || (approvalAll[o][msg.sender]), "not permitted");
        _transfer(_from, _to, _tokenId);
        if (a != address(0)) {
            approval[_tokenId] = address(0); // clear previous approval
            emit Approval(msg.sender, address(0), _tokenId);
        }
        require(_checkOnERC721Received(_from, _to, _tokenId, ""), "ERC721: transfer to non ERC721Receiver implementer");
    }

    function transferFrom(address _from, address _to, uint256 _tokenId) external regulated(_to) {
        require (_tokenId < max, "index out of range");
        address o = ownership[_tokenId];
        require (o == _from, "_from must be owner");
        address a = approval[_tokenId];
        require (o == msg.sender|| (a == msg.sender) || (approvalAll[o][msg.sender]), "not permitted");
        _transfer(_from, _to, _tokenId);
        if (a != address(0)) {
            approval[_tokenId] = address(0); // clear previous approval
            emit Approval(msg.sender, address(0), _tokenId);
        }
    }

    /**
    * @notice Change or reaffirm the approved address for an NFT
    * @dev The zero address indicates there is no approved address.
    *  Throws unless `msg.sender` is the current NFT owner, or an authorized
    *  operator of the current owner.
    * @param _to The new approved NFT controller
    * @param _tokenId The NFT to approve
    */
    function approve(address _to, uint256 _tokenId) external {
        require (_tokenId < max, "index out of range");
        address o = ownership[_tokenId];
        require (o == msg.sender || isApprovedForAll(o, msg.sender), "action not token permitted");
        approval[_tokenId] = _to;
        emit Approval(msg.sender, _to, _tokenId);
    }
    /**
    * @notice Enable or disable approval for a third party ("operator") to manage
    *  all of `msg.sender`'s assets
    * @dev Emits the ApprovalForAll event. The contract MUST allow
    *  multiple operators per owner.
    * @param _operator Address to add to the set of authorized operators
    * @param _approved True if the operator is approved, false to revoke approval
    */
    function setApprovalForAll(address _operator, bool _approved) external {
        require(msg.sender != _operator, "ERC721: approve to caller");
        approvalAll[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    /**
    * @notice Get the approved address for a single NFT
    * @dev Throws if `_tokenId` is not a valid NFT.
    * @param _tokenId The NFT to find the approved address for
    * @return The approved address for this NFT, or the zero address if there is none
    */
    function getApproved(uint256 _tokenId) public view returns (address) {
        require (_tokenId < max, "index out of range");
        return approval[_tokenId];
    }

    /**
    * @notice Query if an address is an authorized operator for another address
    * @param _owner The address that owns the NFTs
    * @param _operator The address that acts on behalf of the owner
    * @return True if `_operator` is an approved operator for `_owner`, false otherwise
    */
    function isApprovedForAll(address _owner, address _operator) public view returns (bool) {
        return approvalAll[_owner][_operator];
    }

    /**
    * @notice Query if a contract implements an interface
    * @param interfaceId The interface identifier, as specified in ERC-165
    * @dev Interface identification is specified in ERC-165. This function
    *  uses less than 30,000 gas.
    * @return `true` if the contract implements `interfaceID` and
    *  `interfaceID` is not 0xffffffff, `false` otherwise
    */
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return
        interfaceId == type(IERC721).interfaceId ||
        interfaceId == type(IERC721Metadata).interfaceId ||
        interfaceId == type(IERC165).interfaceId ||
        interfaceId == type(IERC721Enumerable).interfaceId ||
        interfaceId == type(IERC721TokenReceiver).interfaceId;
    }

    /**
    * @dev transfer a token from _from to _to
    * @param _from from
    * @param _to to
    * @param _tokenId the token index
    */
    function _transfer(address _from, address _to, uint256 _tokenId) internal {
        balances[_to]++;
        balances[_from]--;
        ownership[_tokenId] = _to;
        emit Transfer(_from, _to, _tokenId);
    }

    // we do not allow NFTs to be send to this contract
    function onERC721Received(address /*_operator*/, address /*_from*/, uint256 /*_tokenId*/, bytes memory /*_data*/) external pure returns (bytes4) {
        revert("nope");
    }

    /**
    * @dev Internal function to invoke {IERC721Receiver-onERC721Received} on a target address.
    * The call is not executed if the target address is not a contract.
    *
    * @param from address representing the previous owner of the given token ID
    * @param to target address that will receive the tokens
    * @param tokenId uint256 ID of the token to be transferred
    * @param _data bytes optional data to send along with the call
    * @return bool whether the call correctly returned the expected magic value
    *
    * credits https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/ERC721.sol
    */
    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) private returns (bool) {
        if (isContract(to)) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, _data) returns (bytes4 retval) {
                return retval == IERC721Receiver.onERC721Received.selector;
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert("ERC721: transfer to non ERC721Receiver implementer");
                } else {
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
            return false; // not needed, but the ide complains that there's "no return statement"
        } else {
            return true;
        }
    }

    /**
     * @dev Returns true if `account` is a contract.
     *
     * credits https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Address.sol
     */
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function toString(uint256 value) public pure returns (string memory) {
        // Inspired by openzeppelin's implementation - MIT licence
        // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Strings.sol#L15
        // this version removes the decimals counting

        uint8 count;
        if (value == 0) {
            return "0";
        }
        uint256 digits = 31;
        // bytes and strings are big endian, so working on the buffer from right to left
        // this means we won't need to reverse the string later
        bytes memory buffer = new bytes(32);
        while (value != 0) {
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
            digits -= 1;
            count++;
        }
        uint256 temp;
        assembly {
            temp := mload(add(buffer, 32))
            temp := shl(mul(sub(32,count),8), temp)
            mstore(add(buffer, 32), temp)
            mstore(buffer, count)
        }
        return string(buffer);
    }
}

interface ICryptoPunks {
    function punkIndexToAddress(uint256 punkIndex) external view returns (address);
}

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}


/**
 * @dev Required interface of an ERC721 compliant contract.
 */
interface IERC721 is IERC165 {
    /**
     * @dev Emitted when `tokenId` token is transferred from `from` to `to`.
     */
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables `approved` to manage the `tokenId` token.
     */
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
     */
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be have been allowed to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @dev Transfers `tokenId` token from `from` to `to`.
     *
     * WARNING: Usage of this method is discouraged, use {safeTransferFrom} whenever possible.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     *
     * Emits an {Approval} event.
     */
    function approve(address to, uint256 tokenId) external;

    /**
     * @dev Returns the account approved for `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function getApproved(uint256 tokenId) external view returns (address operator);

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the caller.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(address operator, bool _approved) external;

    /**
     * @dev Returns if the `operator` is allowed to manage all of the assets of `owner`.
     *
     * See {setApprovalForAll}
     */
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;
}

/**
 * @title ERC-721 Non-Fungible Token Standard, optional metadata extension
 * @dev See https://eips.ethereum.org/EIPS/eip-721
 */
interface IERC721Metadata is IERC721 {
    /**
     * @dev Returns the token collection name.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the token collection symbol.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the Uniform Resource Identifier (URI) for `tokenId` token.
     */
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface IERC721TokenReceiver {
    /// @notice Handle the receipt of an NFT
    /// @dev The ERC721 smart contract calls this function on the
    /// recipient after a `transfer`. This function MAY throw to revert and reject the transfer. Return
    /// of other than the magic value MUST result in the transaction being reverted.
    /// @notice The contract address is always the message sender.
    /// @param _operator The address which called `safeTransferFrom` function
    /// @param _from The address which previously owned the token
    /// @param _tokenId The NFT identifier which is being transferred
    /// @param _data Additional data with no specified format
    /// @return `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
    /// unless throwing
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes memory _data) external returns (bytes4);
}

/// @title ERC-721 Non-Fungible Token Standard, optional enumeration extension
/// @dev See https://eips.ethereum.org/EIPS/eip-721
///  Note: the ERC-165 identifier for this interface is 0x780e9d63.
interface IERC721Enumerable {
    /// @notice Count NFTs tracked by this contract
    /// @return A count of valid NFTs tracked by this contract, where each one of
    ///  them has an assigned and queryable owner not equal to the zero address
    function totalSupply() external view returns (uint256);

    /// @notice Enumerate valid NFTs
    /// @dev Throws if `_index` >= `totalSupply()`.
    /// @param _index A counter less than `totalSupply()`
    /// @return The token identifier for the `_index`th NFT,
    ///  (sort order not specified)
    function tokenByIndex(uint256 _index) external view returns (uint256);

    /// @notice Enumerate NFTs assigned to an owner
    /// @dev Throws if `_index` >= `balanceOf(_owner)` or if
    ///  `_owner` is the zero address, representing invalid NFTs.
    /// @param _owner An address where we are interested in NFTs owned by them
    /// @param _index A counter less than `balanceOf(_owner)`
    /// @return The token identifier for the `_index`th NFT assigned to `_owner`,
    ///   (sort order not specified)
    function tokenOfOwnerByIndex(address _owner, uint256 _index) external view returns (uint256);
}




/**
 * @title ERC721 token receiver interface
 * @dev Interface for any contract that wants to support safeTransfers
 * from ERC721 asset contracts.
 */
interface IERC721Receiver {
    /**
     * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * by `operator` from `from`, this function is called.
     *
     * It must return its Solidity selector to confirm the token transfer.
     * If any other value is returned or the interface is not implemented by the recipient, the transfer will be reverted.
     *
     * The selector can be obtained in Solidity with `IERC721.onERC721Received.selector`.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

/*
 * @dev Interface of the ERC20 standard as defined in the EIP.
 * 0xTycoon was here
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface ICigtoken is IERC20 {
    function The_CEO() external view returns (address);
    function CEO_punk_index() external view returns (uint256);
    function taxBurnBlock() external view returns (uint256);
    function CEO_price() external view returns (uint256);
}