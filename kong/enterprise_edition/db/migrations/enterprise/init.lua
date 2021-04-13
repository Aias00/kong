-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

return {
  "000_base",
  "006_1301_to_1500",
  "006_1301_to_1302",
  -- 010 must be ran before 007 because it creates table
  -- that 007 backs up data to
  "010_1500_to_2100",
  "007_1500_to_1504",
  "008_1504_to_1505",
  "007_1500_to_2100",
  "009_1506_to_1507",
  "009_2100_to_2200",
  "010_2200_to_2211",
  "010_2200_to_2300",
  "010_2200_to_2300_1",
}
