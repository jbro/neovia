-- Editor utilities
return {
  -- Auto-detect indentation per buffer
  {
    "tpope/vim-sleuth",
    event = { "BufReadPre", "BufNewFile" },
  },
}
